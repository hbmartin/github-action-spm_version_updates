# frozen_string_literal: true

require "spm_version_updates/package_resolved"
require "spm_version_updates/xcode_parser"
require "spm_version_updates/xcode_project_package_reader"
require "xcodeproj"

# Legacy Xcode project parser used by the Danger plugin API.
module Xcode
  # Find the configured SPM dependencies in the xcodeproj
  # @param   [String] xcodeproj_path
  #          The path of the Xcode project
  # @return [Hash<String, Hash>]
  def self.get_packages(xcodeproj_path)
    raise(XcodeprojPathMustBeSet) if xcodeproj_path.nil? || xcodeproj_path.empty?

    XcodeProjectPackageReader.package_references(xcodeproj_path).to_h { |package|
      repository_url = package.repository_url
      [Git.trim_repo_url(repository_url), package.requirement]
    }
  end

  # Extracts resolved versions from Package.resolved relative to an Xcode project.
  # When a block is given, malformed resolved files are reported to it as
  # `(resolved_path, error)` and skipped; without a block the error is raised.
  # @param   [String] xcodeproj_path
  #          The path to your Xcode project
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

    Kernel.warn("Checked Package.resolved paths: #{checked}")
    Kernel.warn("Found Package.resolved paths: #{locations}")
    locations
  end

  private_class_method :find_packages_resolved_file

  # Raised when Danger plugin Xcode mode is invoked without a project path.
  # Aliased to the core parser's class so plugin callers rescuing the legacy
  # name keep working now that the plugin delegates to SpmChecker/XcodeParser.
  XcodeprojPathMustBeSet = XcodeParser::XcodeprojPathMustBeSet

  # Raised when a Danger plugin Xcode project has no Package.resolved file.
  CouldNotFindResolvedFile = XcodeParser::CouldNotFindResolvedFile
end
