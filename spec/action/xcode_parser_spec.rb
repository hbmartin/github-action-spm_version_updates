# frozen_string_literal: true

require_relative "../../lib/xcode_parser"

RSpec.describe XcodeParser do
  describe ".get_packages" do
    it "handles package references with nil repository URLs" do
      requirement = { "kind" => "branch", "branch" => "main" }
      package = double("XCRemoteSwiftPackageReference", repositoryURL: nil, requirement: requirement)
      project = double("Xcodeproj::Project", objects: [package])

      allow(package).to receive(:kind_of?)
        .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
        .and_return(true)
      allow(Xcodeproj::Project).to receive(:open).with("App.xcodeproj").and_return(project)

      expect(described_class.get_packages("App.xcodeproj")).to eq(
        "" => { "repository_url" => "", "requirement" => requirement }
      )
    end
  end
end
