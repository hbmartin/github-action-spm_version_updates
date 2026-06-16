# frozen_string_literal: true

require_relative "errors"
require_relative "git_operations"
require_relative "package_resolved"

# Parses Swift Package Manager manifests (`Package.swift`) and their adjacent
# `Package.resolved` files.
#
# This supports the "SwiftPM-native" repo layout, where dependencies are
# declared directly in one or more `Package.swift` manifests rather than as
# `XCRemoteSwiftPackageReference` objects inside an `.xcodeproj`.
#
# Manifests are parsed with a lightweight, dependency-free scanner so the action
# runs on any runner (e.g. `ubuntu-latest`) without requiring Swift or a
# macOS/Xcode toolchain to be installed.
#
# The requirement hashes returned by {get_packages} intentionally mirror the
# shape produced by `Xcodeproj` for `XCRemoteSwiftPackageReference#requirement`
# (`"kind"`, `"minimumVersion"`, `"maximumVersion"`, `"version"`, `"branch"`,
# `"revision"`) so the same comparison logic can be reused for both modes.
module ManifestParser
  PACKAGE_CALL = ".package("
  # Raw body and byte offsets for a direct `.package(...)` declaration.
  PackageCallSpan = Struct.new(:body, :body_start, :body_end, keyword_init: true)

  # Find the direct SPM dependencies declared in a `Package.swift` manifest.
  #
  # Local packages (declared with `path:`) and packages without a recognizable
  # version requirement are skipped.
  #
  # Keyed by the normalized repository URL (used to match against
  # `Package.resolved` pins and `ignore-repos`), while the original,
  # scheme-bearing `repository_url` is retained for git operations.
  #
  # @param  [String] manifest_path The path to a `Package.swift` file
  # @yield  [Hash] optionally receives `{ reason:, snippet: }` for each
  #         `.package(...)` declaration that had to be skipped, so callers can
  #         surface parse warnings instead of dropping dependencies silently
  # @raise  [ManifestPathMustBeSet] if the manifest_path is blank
  # @raise  [CouldNotFindManifest] if the file does not exist
  # @return [Hash<String, Hash>] normalized URL => { "repository_url", "requirement" }
  def self.get_packages(manifest_path, &on_skip)
    raise(ManifestPathMustBeSet) if manifest_path.nil? || manifest_path.empty?
    raise(CouldNotFindManifest, manifest_path) unless File.exist?(manifest_path)

    content = strip_comments(File.read(manifest_path))
    package_calls(content, &on_skip).each_with_object({}) { |call, packages|
      if call.include?("\\(")
        on_skip&.call({ reason: "unsupported_string_interpolation", snippet: call })
        next
      end
      if call.match?(/#+"/)
        on_skip&.call({ reason: "unsupported_raw_string", snippet: call })
        next
      end

      url = call[/\burl\s*:\s*"([^"]+)"/, 1]
      next if url.nil? # local package (path:) or otherwise unrecognized

      requirement = requirement_for(call)
      if requirement.nil?
        on_skip&.call({ reason: "unrecognized_requirement", snippet: call })
        next
      end

      packages[GitOperations.trim_repo_url(url)] = { "repository_url" => url, "requirement" => requirement }
    }
  end

  # Extract the resolved versions from a `Package.resolved` file.
  #
  # @param  [String] resolved_path The path to a `Package.resolved` file
  # @return [Hash<String, String>] normalized repository URL => version or revision
  def self.get_resolved_versions(resolved_path)
    PackageResolved.versions_from(resolved_path)
  end

  # Infer the `Package.resolved` path that sits next to a manifest.
  #
  # @param  [String] manifest_path The path to a `Package.swift` file
  # @return [String]
  def self.default_resolved_path(manifest_path)
    File.join(File.dirname(manifest_path), "Package.resolved")
  end

  # Extract raw source spans for `.package(...)` calls. Offsets are byte indexes
  # into the original content and point to the call body, excluding outer parens.
  #
  # @param [String] content raw manifest source
  # @return [Array<PackageCallSpan>]
  def self.package_call_spans(content)
    package_spans(content).map { |span| PackageCallSpan.new(**span) }
  end

  # Extract the argument body of each `.package( ... )` call, honoring nested
  # parentheses (e.g. `.upToNextMajor(from: "1.0.0")`) and string literals.
  #
  # An unclosed call cannot be skipped safely (there is no closing paren to
  # resume after), so scanning stops there; the skip callback says so.
  #
  # @param  [String] content The (comment-stripped) manifest source
  # @return [Array<String>]
  def self.package_calls(content, &on_skip)
    package_spans(content, &on_skip).map { |span| span[:body] }
  end

  def self.package_spans(content, &on_skip)
    calls = []
    search_start = 0
    while (marker_index = next_package_call(content, search_start))
      open_index = marker_index + PACKAGE_CALL.length - 1
      close_index = matching_paren(content, open_index)
      if close_index.nil?
        on_skip&.call({ reason: "unbalanced_parentheses", snippet: content[marker_index, 300] })
        break
      end

      body_start = open_index + 1
      calls << { body: content[body_start...close_index], body_start:, body_end: close_index }
      search_start = close_index + 1
    end
    calls
  end

  def self.next_package_call(content, search_start)
    index = search_start
    while index < content.length
      return index if content[index, PACKAGE_CALL.length] == PACKAGE_CALL

      if (raw_string = raw_string_start(content, index))
        index = skip_raw_string_literal(content, index, raw_string)
      elsif content[index] == '"'
        index = skip_string_literal(content, index)
      else
        index += 1
      end
    end
    nil
  end

  # Map the body of a `.package(...)` call to an Xcodeproj-style requirement.
  #
  # Ordering matters: ranges and the explicit `.upToNextMajor`/`.upToNextMinor`
  # forms are matched before the bare `from:` shorthand because they also
  # contain the substring `from:`.
  #
  # @param  [String] call The body of a `.package(...)` call
  # @return [Hash, nil]
  def self.requirement_for(call)
    if (range = call.match(/"([^"]+)"\s*(\.\.[.<])\s*"([^"]+)"/))
      version_range_requirement(range[1], range[2], range[3])
    elsif (version = call[/\.upToNextMinor\s*\(\s*from\s*:\s*"([^"]+)"/, 1])
      { "kind" => "upToNextMinorVersion", "minimumVersion" => version }
    elsif (version = call[/\.upToNextMajor\s*\(\s*from\s*:\s*"([^"]+)"/, 1] || call[/\bfrom\s*:\s*"([^"]+)"/, 1])
      { "kind" => "upToNextMajorVersion", "minimumVersion" => version }
    elsif (version = call[/\bexact\s*:\s*"([^"]+)"/, 1] || call[/\.exact\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "exactVersion", "version" => version }
    elsif (branch = call[/\bbranch\s*:\s*"([^"]+)"/, 1] || call[/\.branch\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "branch", "branch" => branch }
    elsif (revision = call[/\brevision\s*:\s*"([^"]+)"/, 1] || call[/\.revision\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "revision", "revision" => revision }
    end
  end

  # Build a versionRange requirement from a Swift range literal.
  #
  # Xcode's `versionRange` (like Swift's `..<`) uses an exclusive maximum. SwiftPM
  # normalizes a closed range `a...b` to the half-open range `a ..< (b + 1 patch)`,
  # so we do the same here for `...` to keep the inclusive upper bound — otherwise
  # version `b` would be incorrectly excluded from update checks.
  #
  # @return [Hash]
  def self.version_range_requirement(minimum, range_operator, maximum)
    maximum = increment_patch_version(maximum) if range_operator == "..."
    { "kind" => "versionRange", "minimumVersion" => minimum, "maximumVersion" => maximum }
  end

  # Increment the patch component of an `x.y.z` version, dropping any
  # pre-release/build suffix (matching how SwiftPM derives the exclusive upper
  # bound of a closed range as `Version(major, minor, patch + 1)`). Returns the
  # input unchanged if it is not a three-part version.
  #
  # @return [String]
  def self.increment_patch_version(version)
    major, minor, patch = version.match(/\A(\d+)\.(\d+)\.(\d+)/)&.captures
    return version if patch.nil?

    "#{major}.#{minor}.#{patch.to_i + 1}"
  end

  # Find the index of the `)` that closes the `(` at +open_index+, ignoring
  # parentheses and the like that appear inside string literals.
  #
  # @return [Integer, nil]
  def self.matching_paren(content, open_index)
    depth = 0
    index = open_index
    length = content.length
    in_string = false
    while index < length
      char = content[index]
      if in_string
        if char == "\\"
          index += 2
          next
        end
        in_string = false if char == '"'
      elsif (raw_string = raw_string_start(content, index))
        index = skip_raw_string_literal(content, index, raw_string)
        next
      elsif char == '"'
        in_string = true
      elsif char == "("
        depth += 1
      elsif char == ")"
        depth -= 1
        return index if depth.zero?
      end
      index += 1
    end
    nil
  end

  # Remove `//` line comments and `/* */` block comments while leaving string
  # literals (e.g. URLs containing `//`) untouched.
  #
  # @param  [String] content The raw manifest source
  # @return [String]
  def self.strip_comments(content)
    output = +""
    index = 0
    length = content.length
    while index < length
      char = content[index]
      nxt = content[index + 1]
      if (raw_string = raw_string_start(content, index))
        index = copy_raw_string_literal(content, index, output, raw_string)
      elsif char == '"'
        index = copy_string_literal(content, index, output)
      elsif char == "/" && nxt == "/"
        index += 1 while index < length && content[index] != "\n"
      elsif char == "/" && nxt == "*"
        index = skip_block_comment(content, index)
      else
        output << char
        index += 1
      end
    end
    output
  end

  # Copy a double-quoted string literal verbatim into +output+, respecting
  # backslash escapes, and return the index just past the closing quote.
  #
  # @return [Integer]
  def self.copy_string_literal(content, index, output)
    length = content.length
    output << content[index] # opening quote
    index += 1
    while index < length
      char = content[index]
      output << char
      if char == "\\"
        output << content[index + 1] if index + 1 < length
        index += 2
        next
      end
      index += 1
      break if char == '"'
    end
    index
  end

  def self.skip_string_literal(content, index)
    length = content.length
    index += 1
    while index < length
      char = content[index]
      if char == "\\"
        index += 2
        next
      end

      index += 1
      break if char == '"'
    end
    index
  end

  def self.raw_string_start(content, index)
    hash_count = 0
    hash_index = index
    while content[hash_index] == "#"
      hash_count += 1
      hash_index += 1
    end
    return nil unless hash_count.positive?

    quote_count = raw_string_quote_count(content, hash_index)
    return nil unless quote_count.positive?

    [hash_count, quote_count]
  end

  def self.raw_string_quote_count(content, index)
    return 3 if content[index, 3] == '"""'
    return 1 if content[index] == '"'

    0
  end

  def self.raw_string_end?(content, index, hash_count, quote_count)
    return false unless content[index, quote_count] == '"' * quote_count

    content[(index + quote_count), hash_count] == "#" * hash_count
  end

  def self.copy_raw_string_literal(content, index, output, raw_string)
    start = index
    index = skip_raw_string_literal(content, index, raw_string)
    output << content[start...index]
    index
  end

  def self.skip_raw_string_literal(content, index, raw_string)
    hash_count, quote_count = raw_string
    index += hash_count + quote_count
    while index < content.length
      return index + quote_count + hash_count if raw_string_end?(content, index, hash_count, quote_count)

      index += 1
    end
    index
  end

  # Return the index just past the closing `*/` of a block comment. Swift block
  # comments nest, so depth is tracked: `/* a /* b */ c */` is a single comment.
  #
  # @return [Integer]
  def self.skip_block_comment(content, index)
    length = content.length
    depth = 1
    index += 2 # skip the opening "/*"
    while index < length && depth.positive?
      if content[index] == "/" && content[index + 1] == "*"
        depth += 1
        index += 2
      elsif content[index] == "*" && content[index + 1] == "/"
        depth -= 1
        index += 2
      else
        index += 1
      end
    end
    index
  end

  private_class_method :package_calls,
                       :package_spans,
                       :next_package_call,
                       :version_range_requirement,
                       :increment_patch_version,
                       :matching_paren,
                       :strip_comments,
                       :copy_string_literal,
                       :skip_string_literal,
                       :raw_string_start,
                       :raw_string_quote_count,
                       :raw_string_end?,
                       :copy_raw_string_literal,
                       :skip_raw_string_literal,
                       :skip_block_comment

  # Raised when manifest mode is invoked without a manifest path.
  class ManifestPathMustBeSet < SpmVersionUpdates::ConfigurationError
    def initialize(message = "package-manifest-paths must be set")
      super
    end
  end

  # Raised when a configured Package.swift manifest is missing.
  class CouldNotFindManifest < SpmVersionUpdates::FileNotFoundError
    def initialize(path)
      super("Could not find Package.swift manifest: #{path}")
    end
  end

  # Raised when manifest mode cannot find an expected Package.resolved file.
  class CouldNotFindResolvedFile < SpmVersionUpdates::FileNotFoundError
    def initialize(paths)
      super(
        "Could not find any Package.resolved file (looked in: #{paths}). " \
        "Commit a Package.resolved next to each manifest or set package-resolved-paths."
      )
    end
  end
end
