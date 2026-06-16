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

  # Navigates a normal Swift double-quoted string literal.
  class StringLiteral
    def initialize(content, index)
      @content = content
      @index = index
      @cursor = index
    end

    def copy_to(output)
      output << @content[@index...skip_index]
      skip_index
    end

    def skip_index
      @cursor = @index + 1
      @cursor = next_cursor until finished?
      finish_index
    end

    private

    def finished?
      @cursor >= @content.length || @content[@cursor] == '"'
    end

    def next_cursor
      @content[@cursor] == "\\" ? @cursor + 2 : @cursor + 1
    end

    def finish_index
      @cursor >= @content.length ? @cursor : @cursor + 1
    end
  end
  private_constant :StringLiteral

  # Navigates a Swift raw string literal such as #"..."# or #"""..."""#.
  class RawStringLiteral
    def initialize(content, index)
      @content = content
      @index = index
      @hash_count = leading_hash_count
      @quote_count = quote_count
    end

    def literal?
      @hash_count.positive? && @quote_count.positive?
    end

    def copy_to(output)
      output << @content[@index...skip_index]
      skip_index
    end

    def skip_index
      length = @content.length
      index = @index + @hash_count + @quote_count
      index += 1 until index >= length || ends_at?(index)
      [index + @quote_count + @hash_count, length].min
    end

    private

    def leading_hash_count
      index = @index
      index += 1 while @content[index] == "#"
      index - @index
    end

    def quote_count
      quote_index = @index + @hash_count
      return 3 if @content[quote_index, 3] == '"""'
      return 1 if @content[quote_index] == '"'

      0
    end

    def ends_at?(index)
      @content[index, @quote_count] == '"' * @quote_count &&
        @content[(index + @quote_count), @hash_count] == "#" * @hash_count
    end
  end
  private_constant :RawStringLiteral

  # Finds `.package(` markers while skipping Swift string literals.
  class PackageCallFinder
    def initialize(content)
      @content = content
    end

    def next_from(search_start)
      index = search_start
      while index < @content.length
        return index if package_call_at?(index)

        index = next_index(index)
      end
      nil
    end

    private

    def package_call_at?(index)
      @content[index, PACKAGE_CALL.length] == PACKAGE_CALL
    end

    def next_index(index)
      raw_string = RawStringLiteral.new(@content, index)
      return raw_string.skip_index if raw_string.literal?
      return StringLiteral.new(@content, index).skip_index if @content[index] == '"'

      index + 1
    end
  end
  private_constant :PackageCallFinder

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
    scan_package_spans(content, on_skip) { |span| calls << span }
    calls
  end

  def self.scan_package_spans(content, on_skip)
    search_start = 0
    while (marker_index = next_package_call(content, search_start))
      span = package_span(content, marker_index, on_skip)
      break unless span

      yield(span)
      search_start = span[:body_end] + 1
    end
  end

  def self.package_span(content, marker_index, on_skip)
    open_index = marker_index + PACKAGE_CALL.length - 1
    close_index = matching_paren(content, open_index)
    return unbalanced_package_span(content, marker_index, on_skip) unless close_index

    body_start = open_index + 1
    { body: content[body_start...close_index], body_start:, body_end: close_index }
  end

  def self.unbalanced_package_span(content, marker_index, on_skip)
    on_skip&.call({ reason: "unbalanced_parentheses", snippet: content[marker_index, 300] })
    nil
  end

  def self.next_package_call(content, search_start)
    PackageCallFinder.new(content).next_from(search_start)
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
    while index < length
      char = content[index]
      raw_string = RawStringLiteral.new(content, index)
      if raw_string.literal?
        index = raw_string.skip_index
        next
      elsif char == '"'
        index = StringLiteral.new(content, index).skip_index
        next
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
      raw_string = RawStringLiteral.new(content, index)
      if raw_string.literal?
        index = raw_string.copy_to(output)
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
    StringLiteral.new(content, index).copy_to(output)
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
                       :scan_package_spans,
                       :package_span,
                       :unbalanced_package_span,
                       :next_package_call,
                       :version_range_requirement,
                       :increment_patch_version,
                       :matching_paren,
                       :strip_comments,
                       :copy_string_literal,
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
