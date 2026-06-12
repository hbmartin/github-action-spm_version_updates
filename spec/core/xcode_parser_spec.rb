# frozen_string_literal: true

require "fileutils"
require "json"
require "spm_version_updates/xcode_parser"
require "stringio"
require "tmpdir"
require "xcodeproj"

RSpec.describe XcodeParser do
  let(:resolved_writer) {
    lambda { |path, url:, version:|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(
        path,
        JSON.pretty_generate(
          "pins" => [
            {
              "location" => url,
              "state" => { "version" => version }
            },
          ]
        )
      )
    }
  }

  describe ".get_packages" do
    it "extracts remote Swift packages through the lightweight pbxproj reader", :aggregate_failures do
      project_path = File.expand_path("../support/fixtures/UpToNextMajor.xcodeproj", __dir__)

      allow(Xcodeproj::Project).to receive(:open).and_call_original

      expect(described_class.get_packages(project_path)).to eq(
        "github.com/kean/Nuke" => {
          "repository_url" => "https://github.com/kean/Nuke",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "12.1.6" }
        }
      )
      expect(Xcodeproj::Project).not_to have_received(:open)
    end

    it "warns and falls back when the lightweight pbxproj parser cannot read the file", :aggregate_failures do
      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(project_path)
        File.write(File.join(project_path, "project.pbxproj"), "broken")
        allow(XcodeProjectPackageReader).to receive(:pbxproj_objects)
          .and_raise(Xcodeproj::Informative, "invalid plist")

        result = nil
        expect {
          result = XcodeProjectPackageReader.send(:package_references_from_pbxproj, project_path)
        }.to output(/falling back to full Xcode project parsing/).to_stderr
        expect(result).to be_nil
      end
    end

    it "warns and falls back when CFPropertyList rejects the pbxproj file", :aggregate_failures do
      cfplist_error = Class.new(StandardError)
      fallback_errors = XcodeProjectPackageReader.const_get(:PbxprojFallbackErrors, false)
      allow(fallback_errors).to receive(:loaded_nested_constant).and_call_original
      allow(fallback_errors).to receive(:loaded_nested_constant)
        .with(:CFPropertyList, :CFPlistError)
        .and_return(cfplist_error)

      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(project_path)
        File.write(File.join(project_path, "project.pbxproj"), "broken")
        allow(XcodeProjectPackageReader).to receive(:pbxproj_objects)
          .and_raise(cfplist_error, "invalid plist")

        result = nil
        expect {
          result = XcodeProjectPackageReader.send(:package_references_from_pbxproj, project_path)
        }.to output(/falling back to full Xcode project parsing/).to_stderr
        expect(result).to be_nil
      end
    end

    it "ignores fallback error namespaces that are not modules" do
      fallback_errors = XcodeProjectPackageReader.const_get(:PbxprojFallbackErrors, false)

      expect(fallback_errors.loaded_constant("not a module", :CFPlistError)).to be_nil
    end

    it "does not swallow unexpected bugs in the lightweight pbxproj reader" do
      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "App.xcodeproj")
        FileUtils.mkdir_p(project_path)
        File.write(File.join(project_path, "project.pbxproj"), "{}")
        allow(XcodeProjectPackageReader).to receive(:pbxproj_objects)
          .and_raise(NoMethodError, "unexpected bug")

        expect {
          XcodeProjectPackageReader.send(:package_references_from_pbxproj, project_path)
        }.to raise_error(NoMethodError, /unexpected bug/)
      end
    end

    it "ignores package references with nil or blank repository URLs" do
      requirement = { "kind" => "branch", "branch" => "main" }
      nil_url_package = instance_double(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference, repositoryURL: nil, requirement:)
      blank_url_package = instance_double(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference, repositoryURL: "   ", requirement:)
      project = instance_double(Xcodeproj::Project, objects: [nil_url_package, blank_url_package])

      [nil_url_package, blank_url_package].each do |package|
        allow(package).to receive(:kind_of?)
          .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
          .and_return(true)
      end
      allow(Xcodeproj::Project).to receive(:open).with("App.xcodeproj").and_return(project)

      expect(described_class.get_packages("App.xcodeproj")).to eq({})
    end
  end

  describe ".get_resolved_versions" do
    it "derives workspace paths by replacing only the terminal .xcodeproj extension", :aggregate_failures do
      Dir.mktmpdir("xcode-parser") do |dir|
        container = File.join(dir, "directory-with-xcodeproj-in-name")
        project_path = File.join(container, "Sample App.xcodeproj")
        workspace_resolved = File.join(container, "Sample App.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
        resolved_writer.call(workspace_resolved, url: "https://github.com/acme/Package", version: "1.2.3")

        stdout = capture_stdout do
          expect(described_class.get_resolved_versions(project_path)).to eq(
            "github.com/acme/Package" => "1.2.3"
          )
        end

        expect(stdout).to include("Checked Package.resolved paths:")
        expect(stdout).to include("Found Package.resolved paths:")
        expect(stdout).to include(workspace_resolved)
        expect(stdout).not_to include("directory-with-xcworkspace-in-name")
      end
    end

    it "does not derive an adjacent workspace path when the project path has no .xcodeproj extension" do
      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "Sample App")

        expect(XcodeProjectPackageReader.package_resolved_candidate_paths(project_path)).to eq(
          [
            File.join(project_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"),
          ]
        )
      end
    end

    it "derives adjacent workspace paths when the project path has a trailing slash" do
      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "Sample App.xcodeproj")
        workspace_resolved = File.join(dir, "Sample App.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")

        expect(XcodeProjectPackageReader.package_resolved_candidate_paths("#{project_path}/")).to include(workspace_resolved)
      end
    end

    it "merges adjacent workspace and project-local resolved files" do
      Dir.mktmpdir("xcode-parser") do |dir|
        project_path = File.join(dir, "Sample App.xcodeproj")
        workspace_resolved = File.join(dir, "Sample App.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
        project_resolved = File.join(project_path, "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
        resolved_writer.call(workspace_resolved, url: "https://github.com/acme/One", version: "1.0.0")
        resolved_writer.call(project_resolved, url: "https://github.com/acme/Two", version: "2.0.0")

        capture_stdout do
          expect(described_class.get_resolved_versions(project_path)).to eq(
            "github.com/acme/One" => "1.0.0",
            "github.com/acme/Two" => "2.0.0"
          )
        end
      end
    end
  end

  def capture_stdout
    original_stdout = $stdout
    captured = StringIO.new
    $stdout = captured

    yield
    captured.string
  ensure
    $stdout = original_stdout
  end
end
