# frozen_string_literal: true

require "xcodeproj"

# Reads Swift package references and adjacent Package.resolved locations for an
# Xcode project without requiring Xcode to be installed.
module XcodeProjectPackageReader
  PackageReference = Struct.new(:repository_url, :requirement, keyword_init: true)
  private_constant :PackageReference

  def self.package_references(xcodeproj_path)
    package_references_from_pbxproj(xcodeproj_path) || package_references_from_project(xcodeproj_path)
  end

  def self.package_resolved_candidate_paths(xcodeproj_path)
    [
      workspace_resolved_path(xcodeproj_path),
      File.join(xcodeproj_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"),
    ].compact
  end

  def self.package_references_from_pbxproj(xcodeproj_path)
    pbxproj_path = File.join(xcodeproj_path, "project.pbxproj")
    return nil unless File.file?(pbxproj_path)

    objects = Xcodeproj::Plist.read_from_path(pbxproj_path).fetch("objects", {})
    objects.values.filter_map { |object| package_reference_from_plist_object(object) }
  rescue StandardError
    nil
  end

  def self.package_reference_from_plist_object(object)
    return unless object["isa"] == "XCRemoteSwiftPackageReference"

    repository_url = object["repositoryURL"]
    return if repository_url.to_s.strip.empty?

    PackageReference.new(repository_url:, requirement: object["requirement"])
  end

  def self.package_references_from_project(xcodeproj_path)
    Xcodeproj::Project.open(xcodeproj_path).objects.filter_map { |object|
      next unless object.kind_of?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
      next if object.repositoryURL.to_s.strip.empty?

      PackageReference.new(repository_url: object.repositoryURL, requirement: object.requirement)
    }
  end

  def self.workspace_resolved_path(xcodeproj_path)
    return unless xcodeproj_path.end_with?(".xcodeproj")

    workspace = xcodeproj_path.sub(/\.xcodeproj\z/, ".xcworkspace")
    File.join(workspace, "xcshareddata", "swiftpm", "Package.resolved")
  end

  private_class_method :package_references_from_pbxproj,
                       :package_reference_from_plist_object,
                       :package_references_from_project,
                       :workspace_resolved_path
end
