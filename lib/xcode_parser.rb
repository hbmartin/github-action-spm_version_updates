# frozen_string_literal: true

require "xcodeproj"
require_relative "git_operations"
require_relative "package_resolved"

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

    remote_swift_packages(Xcodeproj::Project.open(xcodeproj_path)).to_h { |package|
      repository_url = package.repositoryURL
      [
        GitOperations.trim_repo_url(repository_url),
        { "repository_url" => repository_url, "requirement" => package.requirement },
      ]
    }
  end

  # Extracts resolved versions from Package.resolved relative to an Xcode project
  # @param   [String] xcodeproj_path The path to your Xcode project
  # @raise [CouldNotFindResolvedFile] if no Package.resolved files were found
  # @return [Hash<String, String>]
  def self.get_resolved_versions(xcodeproj_path)
    resolved_paths = find_packages_resolved_file(xcodeproj_path)
    raise(CouldNotFindResolvedFile) if resolved_paths.empty?

    resolved_paths.each_with_object({}) { |resolved_path, pins| pins.merge!(PackageResolved.versions_from(resolved_path)) }
  end

  # Find the Packages.resolved file
  # @return [Array<String>]
  def self.find_packages_resolved_file(xcodeproj_path)
    # First check the workspace for a resolved file
    workspace = xcodeproj_path.sub("xcodeproj", "xcworkspace")
    workspace_resolved = File.join(workspace, "xcshareddata", "swiftpm", "Package.resolved")

    # Then check the project for a resolved file
    project_resolved = File.join(xcodeproj_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
    locations = [workspace_resolved, project_resolved].select { |path| File.exist?(path) }

    puts("Searching for resolved packages in: #{locations}")
    locations
  end

  def self.remote_swift_packages(project)
    project.objects.select { |obj|
      obj.kind_of?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference) &&
        !obj.repositoryURL.to_s.strip.empty?
    }
  end

  private_class_method :find_packages_resolved_file, :remote_swift_packages

  # Raised when Xcode project mode is invoked without a project path.
  class XcodeprojPathMustBeSet < StandardError
  end

  # Raised when an Xcode project does not have a Package.resolved file.
  class CouldNotFindResolvedFile < StandardError
  end
end
