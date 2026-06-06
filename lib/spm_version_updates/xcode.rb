# frozen_string_literal: true

require "xcodeproj"

# Legacy Xcode project parser used by the Danger plugin API.
module Xcode
  # Find the configured SPM dependencies in the xcodeproj
  # @param   [String] xcodeproj_path
  #          The path of the Xcode project
  # @return [Hash<String, Hash>]
  def self.get_packages(xcodeproj_path)
    raise(XcodeprojPathMustBeSet) if xcodeproj_path.nil? || xcodeproj_path.empty?

    remote_swift_packages(Xcodeproj::Project.open(xcodeproj_path)).to_h { |package|
      repository_url = package.repositoryURL
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
    # First check the workspace for a resolved file
    workspace = xcodeproj_path.sub("xcodeproj", "xcworkspace")
    workspace_resolved = File.join(workspace, "xcshareddata", "swiftpm", "Package.resolved")

    # Then check the project for a resolved file
    project_resolved = File.join(xcodeproj_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
    locations = [workspace_resolved, project_resolved].select { |path| File.exist?(path) }

    Kernel.warn("Searching for resolved packages in: #{locations}")
    locations
  end

  def self.remote_swift_packages(project)
    project.objects.select { |obj|
      obj.kind_of?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    }
  end

  private_class_method :find_packages_resolved_file, :remote_swift_packages

  # Raised when Danger plugin Xcode mode is invoked without a project path.
  class XcodeprojPathMustBeSet < StandardError
  end

  # Raised when a Danger plugin Xcode project has no Package.resolved file.
  class CouldNotFindResolvedFile < StandardError
  end
end
