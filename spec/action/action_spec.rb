# frozen_string_literal: true

require_relative "../../lib/action"

# Covers the source-mode selection logic that decides between Xcode-project mode
# and Swift-manifest mode based on the configured inputs.
RSpec.describe Action do
  subject(:action) { described_class.new }

  let(:checker) { instance_double(SpmChecker) }

  def inputs(overrides = {})
    {
      xcode_project_path: nil,
      manifest_paths: [],
      resolved_paths: [],
    }.merge(overrides)
  end

  describe "#run_checks" do
    it "raises when both source modes are provided" do
      both = inputs(xcode_project_path: "App.xcodeproj", manifest_paths: ["Modules/Package.swift"])

      expect { action.send(:run_checks, checker, both) }.to raise_error(Action::ModeError, /not both/)
    end

    it "raises when neither source mode is provided" do
      expect { action.send(:run_checks, checker, inputs) }.to raise_error(Action::ModeError, /either/)
    end

    it "uses Xcode mode when only xcode-project-path is set" do
      allow(checker).to receive(:check_for_updates).and_return([])

      action.send(:run_checks, checker, inputs(xcode_project_path: "App.xcodeproj"))

      expect(checker).to have_received(:check_for_updates).with("App.xcodeproj")
    end

    it "uses manifest mode when package-manifest-paths is set" do
      allow(checker).to receive(:check_manifests).and_return([])
      configured = inputs(manifest_paths: ["Modules/Package.swift"], resolved_paths: ["Modules/Package.resolved"])

      action.send(:run_checks, checker, configured)

      expect(checker).to have_received(:check_manifests).with(["Modules/Package.swift"], ["Modules/Package.resolved"])
    end
  end
end
