# frozen_string_literal: true

require "xcodeproj"
require_relative "../xcode_project_package_reader"

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

  # Extracts resolved versions from Package.resolved relative to an Xcode project
  # @param   [String] xcodeproj_path
  #          The path to your Xcode project
  # @raise [CouldNotFindResolvedFile] if no Package.resolved files were found
  # @return [Hash<String, String>]
  def self.get_resolved_versions(xcodeproj_path)
    resolved_paths = find_packages_resolved_file(xcodeproj_path)
    raise(CouldNotFindResolvedFile) if resolved_paths.empty?

    resolved_versions = resolved_paths.map { |resolved_path|
      contents = JSON.load_file!(resolved_path)
      pins = contents["pins"] || contents["object"]["pins"]
      pins.to_h { |pin|
        state = pin["state"]
        [
          Git.trim_repo_url(pin["location"] || pin["repositoryURL"]),
          state["version"] || state["revision"],
        ]
      }
    }
    resolved_versions.reduce(:merge!)
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
  class XcodeprojPathMustBeSet < StandardError
  end

  # Raised when a Danger plugin Xcode project has no Package.resolved file.
  class CouldNotFindResolvedFile < StandardError
  end
end
