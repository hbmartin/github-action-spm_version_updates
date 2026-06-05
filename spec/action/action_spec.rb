# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/action"

# Covers the source-mode selection logic that decides between Xcode-project mode
# and Swift-manifest mode based on the configured inputs.
RSpec.describe Action do
  subject(:action) { described_class.new }

  let(:checker) { instance_double(SpmChecker) }

  def with_env(overrides)
    original = overrides.to_h { |key, _value| [key, ENV[key]] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }

    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def input_env(overrides = {})
    %w(
      INPUT_XCODE_PROJECT_PATH
      INPUT_PACKAGE_MANIFEST_PATHS
      INPUT_PACKAGE_RESOLVED_PATHS
      INPUT_CHECK_WHEN_EXACT
      INPUT_CHECK_BRANCHES
      INPUT_CHECK_REVISIONS
      INPUT_REPORT_ABOVE_MAXIMUM
      INPUT_REPORT_PRE_RELEASES
      INPUT_IGNORE_REPOS
      INPUT_FAIL_ON_UPDATES
      GITHUB_WORKSPACE
    ).to_h { |key| [key, nil] }.merge(overrides)
  end

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

  describe "#read_inputs" do
    it "parses GitHub Action environment inputs", :aggregate_failures do
      with_env(
        input_env(
          "INPUT_XCODE_PROJECT_PATH" => " App.xcodeproj ",
          "INPUT_PACKAGE_MANIFEST_PATHS" => " Modules/Package.swift\n\nBuildTools/Package.swift ",
          "INPUT_PACKAGE_RESOLVED_PATHS" => " Modules/Package.resolved\nBuildTools/Package.resolved ",
          "INPUT_CHECK_WHEN_EXACT" => "true",
          "INPUT_CHECK_BRANCHES" => "false",
          "INPUT_CHECK_REVISIONS" => "true",
          "INPUT_REPORT_ABOVE_MAXIMUM" => "true",
          "INPUT_REPORT_PRE_RELEASES" => "true",
          "INPUT_IGNORE_REPOS" => " https://github.com/a/b, https://github.com/c/d ",
          "INPUT_FAIL_ON_UPDATES" => "true"
        )
      ) do
        expect(action.send(:read_inputs)).to eq(
          {
            xcode_project_path: "App.xcodeproj",
            manifest_paths: ["Modules/Package.swift", "BuildTools/Package.swift"],
            resolved_paths: ["Modules/Package.resolved", "BuildTools/Package.resolved"],
            check_when_exact: true,
            check_branches: false,
            check_revisions: true,
            report_above_maximum: true,
            report_pre_releases: true,
            ignore_repos: ["https://github.com/a/b", "https://github.com/c/d"],
            fail_on_updates: true,
          }
        )
      end
    end

    it "defaults check_branches to true when the env var is absent" do
      with_env(input_env) do
        expect(action.send(:read_inputs)[:check_branches]).to be(true)
      end
    end
  end

  describe "#report" do
    let(:github_integration) { instance_double(GithubIntegration, post_comment: nil, post_comment_with_warnings: nil) }

    before do
      action.instance_variable_set(:@github_integration, github_integration)
    end

    it "writes outputs, a step summary, annotations, and a PR comment for updates" do
      warnings = ["Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift"]
      warning_details = [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0",
        },
      ]

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        stdout = capture_stdout do
          with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
            action.send(:report, warnings, warning_details)
          end
        end

        expect(File.read(output_path)).to include("updates-found=1")
        expect(output_json_from(output_path)).to eq(
          [
            {
              "type" => "version",
              "package" => "onevcat/Kingfisher",
              "current_version" => "7.0.0",
              "available_version" => "8.0.0",
              "message" => "Newer version of onevcat/Kingfisher: 8.0.0",
              "source" => "Modules/Package.swift",
            },
          ]
        )
        expect(File.read(summary_path)).to include("Found **1** potential dependency update.")
        expect(stdout).to include(
          "::warning title=SPM dependency update,file=Modules/Package.swift::" \
          "Newer version of onevcat/Kingfisher: 8.0.0"
        )
        expect(github_integration).to have_received(:post_comment_with_warnings).with(warnings, warning_details)
      end
    end

    it "writes empty outputs and an up-to-date summary when no updates are found" do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, [])
        end

        expect(File.read(output_path)).to include("updates-found=0")
        expect(output_json_from(output_path)).to eq([])
        expect(File.read(summary_path)).to include("All SPM dependencies are up to date.")
        expect(github_integration).to have_received(:post_comment).with("✅ **SPM Dependencies**: All dependencies are up to date!")
      end
    end
  end

  describe "#run" do
    it "dispatches manifest mode from environment inputs", :aggregate_failures do
      configured_checker = SpmChecker.new
      allow(SpmChecker).to receive(:new).and_return(configured_checker)
      allow(configured_checker).to receive(:check_manifests).and_return([])
      allow(configured_checker).to receive(:check_for_updates)
      allow(action).to receive(:print_config)
      allow(action).to receive(:move_to_workspace)
      allow(action).to receive(:report)

      with_env(
        input_env(
          "INPUT_PACKAGE_MANIFEST_PATHS" => "Modules/Package.swift\nBuildTools/Package.swift",
          "INPUT_PACKAGE_RESOLVED_PATHS" => "Modules/Package.resolved\nBuildTools/Package.resolved"
        )
      ) do
        action.run
      end

      expect(configured_checker).to have_received(:check_manifests).with(
        ["Modules/Package.swift", "BuildTools/Package.swift"],
        ["Modules/Package.resolved", "BuildTools/Package.resolved"]
      )
      expect(configured_checker).not_to have_received(:check_for_updates)
      expect(action).to have_received(:report).with([], [])
    end

    it "dispatches Xcode mode from environment inputs", :aggregate_failures do
      configured_checker = SpmChecker.new
      allow(SpmChecker).to receive(:new).and_return(configured_checker)
      allow(configured_checker).to receive(:check_for_updates).and_return([])
      allow(configured_checker).to receive(:check_manifests)
      allow(action).to receive(:print_config)
      allow(action).to receive(:move_to_workspace)
      allow(action).to receive(:report)

      with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj")) do
        action.run
      end

      expect(configured_checker).to have_received(:check_for_updates).with("App.xcodeproj")
      expect(configured_checker).not_to have_received(:check_manifests)
      expect(action).to have_received(:report).with([], [])
    end

    it "fails after reporting when fail-on-updates is enabled and updates are found" do
      configured_inputs = inputs(fail_on_updates: true)
      allow(action).to receive(:read_inputs).and_return(configured_inputs)
      allow(action).to receive(:print_config)
      allow(action).to receive(:move_to_workspace)
      allow(action).to receive(:configure_checker).and_return(checker)
      allow(action).to receive(:run_checks).and_return(["Newer version of onevcat/Kingfisher: 8.0.0"])
      allow(action).to receive(:report)
      allow(checker).to receive(:warning_details).and_return([])

      expect { action.run }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(action).to have_received(:report).with(["Newer version of onevcat/Kingfisher: 8.0.0"], [])
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

  def output_json_from(path)
    output = File.read(path)
    match = output.match(/updates-json<<(?<delimiter>.+)\n(?<json>.+)\n\k<delimiter>/m)
    JSON.parse(match[:json])
  end
end
