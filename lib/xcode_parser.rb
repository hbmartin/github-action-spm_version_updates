# frozen_string_literal: true

require_relative "git_operations"
require_relative "package_resolved"
require_relative "xcode_project_package_reader"

# Xcode project and Package.resolved parsing (migrated from xcode.rb)
module XcodeParser
  # Find the configured SPM dependencies in the xcodeproj.
  #
  # Keyed by the normalized repository URL (used to match against
  # `Package.resolved` pins and `ignore-repos`), while the original,
  # scheme-bearing `repository_url` is retained for git operations.
  #
  # @param   [String] xcodeproj_path The path of the Xcode project
  # @return [Hash<String, Hash>] normalized URL => { "repository_url", "requirement" }
  def self.get_packages(xcodeproj_path)
    raise(XcodeprojPathMustBeSet) if xcodeproj_path.nil? || xcodeproj_path.empty?

    XcodeProjectPackageReader.package_references(xcodeproj_path).to_h { |package|
      repository_url = package.repository_url
      [
        GitOperations.trim_repo_url(repository_url),
        { "repository_url" => repository_url, "requirement" => package.requirement },
      ]
    }
  end

  # Extracts resolved versions from Package.resolved relative to an Xcode project.
  # When a block is given, malformed resolved files are reported to it as
  # `(resolved_path, error)` and skipped; without a block the error is raised.
  # @param   [String] xcodeproj_path The path to your Xcode project
  # @raise [CouldNotFindResolvedFile] if no Package.resolved files were found
  # @raise [PackageResolved::MalformedFileError] if a resolved file is invalid JSON and no block is given
  # @return [Hash<String, String>]
  def self.get_resolved_versions(xcodeproj_path)
    resolved_paths = find_packages_resolved_file(xcodeproj_path)
    raise(CouldNotFindResolvedFile) if resolved_paths.empty?

    resolved_paths.each_with_object({}) { |resolved_path, pins|
      begin
        pins.merge!(PackageResolved.versions_from(resolved_path))
      rescue PackageResolved::MalformedFileError => error
        raise unless block_given?

        yield(resolved_path, error)
      end
    }
  end

  # Find the Packages.resolved file
  # @return [Array<String>]
  def self.find_packages_resolved_file(xcodeproj_path)
    checked = XcodeProjectPackageReader.package_resolved_candidate_paths(xcodeproj_path)
    locations = checked.select { |path| File.exist?(path) }

    puts("Checked Package.resolved paths: #{checked}")
    puts("Found Package.resolved paths: #{locations}")
    locations
  end

  private_class_method :find_packages_resolved_file

  # Raised when Xcode project mode is invoked without a project path.
  class XcodeprojPathMustBeSet < StandardError
  end

  # Raised when an Xcode project does not have a Package.resolved file.
  class CouldNotFindResolvedFile < StandardError
  end
end
