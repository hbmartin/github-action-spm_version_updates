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

    project = Xcodeproj::Project.open(xcodeproj_path)
    project.objects
      .select { |obj|
        obj.kind_of?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference) &&
          !obj.repositoryURL.to_s.strip.empty?
      }
      .to_h { |package|
        [
          GitOperations.trim_repo_url(package.repositoryURL),
          { "repository_url" => package.repositoryURL, "requirement" => package.requirement },
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
    locations = []
    # First check the workspace for a resolved file
    workspace = xcodeproj_path.sub("xcodeproj", "xcworkspace")
    if Dir.exist?(workspace)
      path = File.join(workspace, "xcshareddata", "swiftpm", "Package.resolved")
      locations << path if File.exist?(path)
    end

    # Then check the project for a resolved file
    path = File.join(xcodeproj_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
    locations << path if File.exist?(path)

    puts("Searching for resolved packages in: #{locations}")
    locations
  end

  private_class_method :find_packages_resolved_file

  class XcodeprojPathMustBeSet < StandardError
  end

  class CouldNotFindResolvedFile < StandardError
  end
end
