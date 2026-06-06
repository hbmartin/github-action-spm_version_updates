# frozen_string_literal: true

# Reads Swift package references and adjacent Package.resolved locations for an
# Xcode project without requiring Xcode to be installed.
module XcodeProjectPackageReader
  # Lightweight package reference read from either project objects or pbxproj data.
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
    read_existing_pbxproj(xcodeproj_path)
  rescue *pbxproj_fallback_errors => error
    warn(pbxproj_fallback_message(pbxproj_path_for(xcodeproj_path), error))
    nil
  end

  def self.read_existing_pbxproj(xcodeproj_path)
    pbxproj_path = existing_pbxproj_path(xcodeproj_path)
    return unless pbxproj_path

    package_references_from_pbxproj_objects(pbxproj_objects(pbxproj_path))
  end

  def self.existing_pbxproj_path(xcodeproj_path)
    pbxproj_path = pbxproj_path_for(xcodeproj_path)
    pbxproj_path if File.file?(pbxproj_path)
  end

  def self.pbxproj_fallback_message(pbxproj_path, error)
    "WARNING: Could not read #{pbxproj_path} with the lightweight pbxproj parser " \
      "(#{error.class}: #{error.message}); falling back to full Xcode project parsing."
  end

  def self.pbxproj_fallback_errors
    [
      SystemCallError,
      IOError,
      defined?(Xcodeproj::Informative) ? Xcodeproj::Informative : nil,
      defined?(Nanaimo::Error) ? Nanaimo::Error : nil,
      defined?(CFPropertyList::CFPlistError) ? CFPropertyList::CFPlistError : nil,
    ].compact
  end

  def self.pbxproj_path_for(xcodeproj_path)
    File.join(xcodeproj_path, "project.pbxproj")
  end

  def self.pbxproj_objects(pbxproj_path)
    load_xcodeproj
    Xcodeproj::Plist.read_from_path(pbxproj_path).fetch("objects", {}).values
  end

  def self.package_references_from_pbxproj_objects(objects)
    objects.filter_map { |object| package_reference_from_plist_object(object) }
  end

  def self.package_reference_from_plist_object(object)
    return unless object["isa"] == "XCRemoteSwiftPackageReference"

    repository_url = object["repositoryURL"]
    return if repository_url.to_s.strip.empty?

    PackageReference.new(repository_url:, requirement: object["requirement"])
  end

  def self.package_references_from_project(xcodeproj_path)
    load_xcodeproj
    package_references_from_project_objects(Xcodeproj::Project.open(xcodeproj_path).objects)
  end

  def self.package_references_from_project_objects(objects)
    objects.filter_map { |object| package_reference_from_project_object(object) }
  end

  def self.package_reference_from_project_object(object)
    return unless object.kind_of?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)

    repository_url = object.repositoryURL
    return if repository_url.to_s.strip.empty?

    PackageReference.new(repository_url:, requirement: object.requirement)
  end

  def self.workspace_resolved_path(xcodeproj_path)
    path = xcodeproj_path.to_s.sub(%r{/+\z}, "")
    return unless path.end_with?(".xcodeproj")

    workspace = path.sub(/\.xcodeproj\z/, ".xcworkspace")
    File.join(workspace, "xcshareddata", "swiftpm", "Package.resolved")
  end

  def self.load_xcodeproj
    require("xcodeproj")
  end

  private_class_method :package_references_from_pbxproj,
                       :read_existing_pbxproj,
                       :existing_pbxproj_path,
                       :pbxproj_fallback_message,
                       :pbxproj_fallback_errors,
                       :pbxproj_path_for,
                       :pbxproj_objects,
                       :package_references_from_pbxproj_objects,
                       :package_reference_from_plist_object,
                       :package_references_from_project,
                       :package_references_from_project_objects,
                       :package_reference_from_project_object,
                       :workspace_resolved_path,
                       :load_xcodeproj
end
