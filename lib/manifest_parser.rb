# frozen_string_literal: true

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

  # Find the direct SPM dependencies declared in a `Package.swift` manifest.
  #
  # Local packages (declared with `path:`) and packages without a recognizable
  # version requirement are skipped.
  #
  # @param  [String] manifest_path The path to a `Package.swift` file
  # @raise  [ManifestPathMustBeSet] if the manifest_path is blank
  # @raise  [CouldNotFindManifest] if the file does not exist
  # @return [Hash<String, Hash>] normalized repository URL => requirement
  def self.get_packages(manifest_path)
    raise(ManifestPathMustBeSet) if manifest_path.nil? || manifest_path.empty?
    raise(CouldNotFindManifest, manifest_path) unless File.exist?(manifest_path)

    content = strip_comments(File.read(manifest_path))
    package_calls(content).each_with_object({}) { |call, packages|
      url = call[/\burl\s*:\s*"([^"]+)"/, 1]
      next if url.nil? # local package (path:) or otherwise unrecognized

      requirement = requirement_for(call)
      next if requirement.nil?

      packages[GitOperations.trim_repo_url(url)] = requirement
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

  # Extract the argument body of each `.package( ... )` call, honoring nested
  # parentheses (e.g. `.upToNextMajor(from: "1.0.0")`) and string literals.
  #
  # @param  [String] content The (comment-stripped) manifest source
  # @return [Array<String>]
  def self.package_calls(content)
    calls = []
    search_start = 0
    while (marker_index = content.index(PACKAGE_CALL, search_start))
      open_index = marker_index + PACKAGE_CALL.length - 1
      close_index = matching_paren(content, open_index)
      break if close_index.nil?

      calls << content[(open_index + 1)...close_index]
      search_start = close_index + 1
    end
    calls
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
    if (range = call.match(/"([^"]+)"\s*\.\.[.<]\s*"([^"]+)"/))
      { "kind" => "versionRange", "minimumVersion" => range[1], "maximumVersion" => range[2] }
    elsif (version = call[/\.upToNextMinor\s*\(\s*from\s*:\s*"([^"]+)"/, 1])
      { "kind" => "upToNextMinorVersion", "minimumVersion" => version }
    elsif (version = call[/\.upToNextMajor\s*\(\s*from\s*:\s*"([^"]+)"/, 1])
      { "kind" => "upToNextMajorVersion", "minimumVersion" => version }
    elsif (version = call[/\bexact\s*:\s*"([^"]+)"/, 1] || call[/\.exact\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "exactVersion", "version" => version }
    elsif (branch = call[/\bbranch\s*:\s*"([^"]+)"/, 1] || call[/\.branch\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "branch", "branch" => branch }
    elsif (revision = call[/\brevision\s*:\s*"([^"]+)"/, 1] || call[/\.revision\s*\(\s*"([^"]+)"/, 1])
      { "kind" => "revision", "revision" => revision }
    elsif (version = call[/\bfrom\s*:\s*"([^"]+)"/, 1])
      { "kind" => "upToNextMajorVersion", "minimumVersion" => version }
    end
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
      if char == '"'
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

  # Return the index just past the closing `*/` of a block comment.
  #
  # @return [Integer]
  def self.skip_block_comment(content, index)
    length = content.length
    index += 2
    index += 1 while index < length && !(content[index] == "*" && content[index + 1] == "/")
    index + 2
  end

  private_class_method :package_calls, :requirement_for, :matching_paren,
    :strip_comments, :copy_string_literal, :skip_block_comment

  class ManifestPathMustBeSet < StandardError
  end

  class CouldNotFindManifest < StandardError
  end

  class CouldNotFindResolvedFile < StandardError
  end
end
