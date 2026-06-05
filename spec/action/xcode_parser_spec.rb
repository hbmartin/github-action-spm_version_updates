# frozen_string_literal: true

require_relative "../../lib/xcode_parser"

RSpec.describe XcodeParser do
  describe ".get_packages" do
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
end
