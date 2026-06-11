# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../../lib/xcode_project_package_reader"

RSpec.describe XcodeProjectPackageReader do
  def fixture(name)
    File.expand_path("../support/fixtures/#{name}.xcodeproj", __dir__)
  end

  def remote_package_double(repository_url:, requirement: { "kind" => "exactVersion" })
    package = Object.new
    allow(package).to receive(:kind_of?)
      .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
      .and_return(true)
    allow(package).to receive_messages(repositoryURL: repository_url, requirement:)
    package
  end

  describe ".package_references" do
    it "reads references from project.pbxproj without opening the full project", :aggregate_failures do
      allow(Xcodeproj::Project).to receive(:open)

      references = described_class.package_references(fixture("UpToNextMajor"))

      expect(references.size).to eq(1)
      expect(references.first.repository_url).to eq("https://github.com/kean/Nuke")
      expect(references.first.requirement).to include("kind" => "upToNextMajorVersion", "minimumVersion" => "12.1.6")
      expect(Xcodeproj::Project).not_to have_received(:open)
    end

    it "skips non-package objects and blank repository URLs in pbxproj data" do
      Dir.mktmpdir do |dir|
        xcodeproj_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(xcodeproj_path)
        File.write(
          File.join(xcodeproj_path, "project.pbxproj"),
          <<~PBXPROJ
            // !$*UTF8*$!
            {
              objects = {
                AA = { isa = XCRemoteSwiftPackageReference; repositoryURL = " "; };
                BB = {
                  isa = XCRemoteSwiftPackageReference;
                  repositoryURL = "https://github.com/foo/bar";
                  requirement = { kind = exactVersion; version = 1.0.0; };
                };
                CC = { isa = PBXProject; };
              };
              rootObject = CC;
            }
          PBXPROJ
        )

        references = described_class.package_references(xcodeproj_path)

        expect(references.map(&:repository_url)).to eq(["https://github.com/foo/bar"])
      end
    end

    it "falls back to opening the project when no project.pbxproj exists" do
      Dir.mktmpdir do |dir|
        xcodeproj_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(xcodeproj_path)
        package = remote_package_double(repository_url: "https://github.com/foo/bar")
        project = instance_double(Xcodeproj::Project, objects: [package])
        allow(Xcodeproj::Project).to receive(:open).with(xcodeproj_path).and_return(project)

        references = described_class.package_references(xcodeproj_path)

        expect(references.map(&:repository_url)).to eq(["https://github.com/foo/bar"])
      end
    end

    it "warns and falls back to opening the project when the pbxproj cannot be parsed", :aggregate_failures do
      Dir.mktmpdir do |dir|
        xcodeproj_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(xcodeproj_path)
        File.write(File.join(xcodeproj_path, "project.pbxproj"), "not a plist {{{")
        package = remote_package_double(repository_url: "https://github.com/foo/bar")
        project = instance_double(Xcodeproj::Project, objects: [package])
        allow(Xcodeproj::Project).to receive(:open).with(xcodeproj_path).and_return(project)

        references = nil
        expect { references = described_class.package_references(xcodeproj_path) }
          .to output(/falling back to full Xcode project parsing/).to_stderr

        expect(references.map(&:repository_url)).to eq(["https://github.com/foo/bar"])
      end
    end
  end

  describe ".package_resolved_candidate_paths" do
    it "returns the sibling workspace location before the project-local location" do
      expect(described_class.package_resolved_candidate_paths("path/to/App.xcodeproj")).to eq(
        [
          "path/to/App.xcworkspace/xcshareddata/swiftpm/Package.resolved",
          "path/to/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        ]
      )
    end

    it "handles trailing slashes on the project path" do
      expect(described_class.package_resolved_candidate_paths("path/to/App.xcodeproj/").first)
        .to eq("path/to/App.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    end

    it "returns only the project-local candidate for non-xcodeproj paths" do
      expect(described_class.package_resolved_candidate_paths("path/to/checkout")).to eq(
        ["path/to/checkout/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
      )
    end

    it "replaces only the terminal .xcodeproj extension" do
      expect(described_class.package_resolved_candidate_paths("nested.xcodeproj.dir/App.xcodeproj").first)
        .to eq("nested.xcodeproj.dir/App.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    end
  end
end
