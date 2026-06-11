# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/action"

# Covers the source-mode selection logic that decides between Xcode-project mode
# and Swift-manifest mode based on the configured inputs.
RSpec.describe Action do
  subject(:action) { described_class.new(reporter_sink:, checker_factory:) }

  let(:checker) { instance_double(SpmChecker) }
  let(:checker_factory) { SpmChecker }
  let(:reporter_sink) {
    instance_double(
      ReporterSink,
      clear: nil,
      configure: nil,
      publish_success: nil,
      publish_updates: nil,
      tracking_issue_result: nil,
      tracking_issue_run?: false
    )
  }

  def with_env(overrides)
    original = overrides.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
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
      INPUT_REPO_RULES_PATH
      INPUT_ALLOW_HOSTS
      INPUT_FAIL_ON_UPDATES
      INPUT_FAIL_ON
      INPUT_COMMENT
      INPUT_COMMENT_ON_SUCCESS
      INPUT_CACHE_VERSION_TAGS
      INPUT_VERSION_TAGS_CACHE_TTL
      SPM_VERSION_UPDATES_TAG_CACHE_DIR
      GITHUB_WORKSPACE
    ).to_h { |key| [key, nil] }
      .merge(overrides)
  end

  def inputs(overrides = {})
    {
      xcode_project_path: nil,
      manifest_paths: [],
      resolved_paths: [],
      allow_hosts: []
    }.merge(overrides)
  end

  describe "#run_checks" do
    it "raises when both source modes are provided" do
      both = inputs(xcode_project_path: "App.xcodeproj", manifest_paths: ["Modules/Package.swift"])

      expect { action.send(:run_checks, checker, both) }
        .to raise_error(Action::ModeError, /not both/)
    end

    it "raises when neither source mode is provided" do
      expect { action.send(:run_checks, checker, inputs) }
        .to raise_error(Action::ModeError, /either/)
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
          "INPUT_REPO_RULES_PATH" => " .spm-version-updates.yml ",
          "INPUT_ALLOW_HOSTS" => " github.com, gitlab.com ",
          "INPUT_FAIL_ON_UPDATES" => "true",
          "INPUT_FAIL_ON" => "minor",
          "INPUT_COMMENT_ON_SUCCESS" => "true"
        )
      ) do
        expect(action.send(:read_inputs)).to eq(expected_parsed_inputs)
      end
    end

    def expected_parsed_inputs
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
        repo_rules_path: ".spm-version-updates.yml",
        allow_hosts: ["github.com", "gitlab.com"],
        fail_on: "minor",
        comment: true,
        comment_on_success: true,
        open_tracking_issue: false,
        cache_version_tags: true,
        version_tags_cache_ttl: 21_600,
        version_tags_cache_dir: nil
      }
    end

    it "defaults check_branches to true when the env var is absent" do
      with_env(input_env) do
        expect(action.send(:read_inputs)[:check_branches]).to be(true)
      end
    end

    it "defaults comment to true when the env var is absent" do
      with_env(input_env) do
        expect(action.send(:read_inputs)[:comment]).to be(true)
      end
    end

    it "uses the legacy fail-on-updates boolean as fail-on any" do
      with_env(input_env("INPUT_FAIL_ON_UPDATES" => "true")) do
        expect(action.send(:read_inputs)[:fail_on]).to eq("any")
      end
    end

    it "parses version tag cache controls", :aggregate_failures do
      with_env(
        input_env(
          "INPUT_CACHE_VERSION_TAGS" => "false",
          "INPUT_VERSION_TAGS_CACHE_TTL" => "3600",
          "SPM_VERSION_UPDATES_TAG_CACHE_DIR" => "/tmp/spm-tags"
        )
      ) do
        parsed = action.send(:read_inputs)

        expect(parsed[:cache_version_tags]).to be(false)
        expect(parsed[:version_tags_cache_ttl]).to eq(3600)
        expect(parsed[:version_tags_cache_dir]).to eq("/tmp/spm-tags")
      end
    end

    it "parses version tag cache TTLs as base 10" do
      with_env(input_env("INPUT_VERSION_TAGS_CACHE_TTL" => "010")) do
        expect(action.send(:read_inputs)[:version_tags_cache_ttl]).to eq(10)
      end
    end

    it "rejects non-integer version tag cache TTLs" do
      with_env(input_env("INPUT_VERSION_TAGS_CACHE_TTL" => "six hours")) do
        expect { action.send(:read_inputs) }
          .to raise_error(ArgumentError, /INPUT_VERSION_TAGS_CACHE_TTL must be an integer/)
      end
    end
  end

  describe "#report" do
    let(:kingfisher_update_record) {
      {
        "type" => "version",
        "package" => "onevcat/Kingfisher",
        "repository_url" => "https://[REDACTED]@github.com/onevcat/Kingfisher",
        "current_version" => "7.0.0",
        "available_version" => "8.0.0",
        "severity" => "major",
        "message" => "Newer version of onevcat/Kingfisher: 8.0.0",
        "source" => "Modules/Package.swift"
      }
    }

    let(:partial_warning_details) {
      [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0",
          message: "Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift",
          source: "Modules/Package.swift"
        },
        nil,
        {
          type: "version",
          package: "orphaned/detail",
          current_version: "1.0.0",
          available_version: "2.0.0"
        },
      ]
    }

    it "writes outputs, a step summary, annotations, and a PR comment for updates", :aggregate_failures do
      warnings = ["Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift"]
      warning_details = [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          repository_url: "https://token@github.com/onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0"
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

        output = File.read(output_path)
        expect(output).to include("updates-found=1", "major-updates-found=1", "minor-updates-found=0", "patch-updates-found=0")
        expect(output_json_from(output_path)).to eq([kingfisher_update_record])
        expect(output).not_to include("token@")
        expect(File.read(summary_path)).to include("Found **1** potential dependency update.")
        expect(stdout).to include(
          "::warning title=SPM dependency update,file=Modules/Package.swift::" \
          "Newer version of onevcat/Kingfisher: 8.0.0"
        )
        expect(reporter_sink).to have_received(:publish_updates).with(warnings, warning_details)
      end
    end

    it "writes tracking-issue outputs when the sink created or updated one" do
      allow(reporter_sink).to receive(:tracking_issue_result)
        .and_return({ number: 7, url: "https://github.com/owner/repo/issues/7" })

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")

        capture_stdout do
          with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => nil) do
            action.send(:report, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil)
          end
        end

        expect(File.read(output_path)).to include(
          "tracking-issue-number=7",
          "tracking-issue-url=https://github.com/owner/repo/issues/7"
        )
      end
    end

    it "skips malformed tracking-issue outputs without raising", :aggregate_failures do
      allow(reporter_sink).to receive(:tracking_issue_result).and_return({ number: 7 })

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")

        stdout = capture_stdout do
          with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => nil) do
            action.send(:report, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil)
          end
        end

        expect(File.read(output_path)).not_to include("tracking-issue")
        expect(stdout).to include("tracking issue result was malformed")
      end
    end

    it "writes no tracking-issue outputs when no issue was touched" do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")

        capture_stdout do
          with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => nil) do
            action.send(:report, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil)
          end
        end

        expect(File.read(output_path)).not_to include("tracking-issue")
      end
    end

    it "keeps every warning when structured details are partial or mismatched", :aggregate_failures do
      warnings = [
        "Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift",
        "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0\nSource: BuildTools/Package.swift",
      ]
      warning_details = partial_warning_details

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, warnings, warning_details)
        end

        output = File.read(output_path)
        expect(output).to include("updates-found=2", "major-updates-found=1", "minor-updates-found=0", "patch-updates-found=0")
        expect(output_json_from(output_path)).to contain_exactly(
          a_hash_including(
            "type" => "version",
            "package" => "onevcat/Kingfisher",
            "severity" => "major",
            "source" => "Modules/Package.swift"
          ),
          {
            "message" => "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0",
            "source" => "BuildTools/Package.swift"
          }
        )
        expect(File.read(summary_path)).to include("Found **2** potential dependency updates.")
      end
    end

    it "does not count revision records as semantic-version severity updates", :aggregate_failures do
      warnings = ["getsentry/sentry-cocoa is pinned to a revision (8.12.0); latest tagged version is 9.0.0"]
      warning_details = [
        {
          type: "revision",
          package: "getsentry/sentry-cocoa",
          current_version: "8.12.0",
          available_version: "9.0.0"
        },
      ]

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, warnings, warning_details)
        end

        output = File.read(output_path)
        expect(output).to include("updates-found=1")
        expect(output).to include("major-updates-found=0")
        expect(output_json_from(output_path).first).not_to include("severity")
      end
    end

    it "writes empty outputs and an up-to-date summary when no updates are found", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, [])
        end

        output = File.read(output_path)
        expect(output).to include("updates-found=0")
        expect(output).to include("major-updates-found=0")
        expect(output).to include("minor-updates-found=0")
        expect(output).to include("patch-updates-found=0")
        expect(output_json_from(output_path)).to eq([])
        expect(File.read(summary_path)).to include("All SPM dependencies are up to date.")
        expect(reporter_sink).to have_received(:clear)
        expect(reporter_sink).not_to have_received(:publish_success)
      end
    end

    it "posts an up-to-date PR comment when success comments are enabled", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, [], nil, comment_on_success: true)
        end

        expect(reporter_sink).to have_received(:publish_success)
        expect(reporter_sink).not_to have_received(:clear)
      end
    end

    it "skips the PR comment for updates when commenting is disabled", :aggregate_failures do
      warnings = ["Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift"]

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, warnings, nil, comment: false)
        end

        expect(File.read(output_path)).to include("updates-found=1")
        expect(File.read(summary_path)).to include("Found **1** potential dependency update.")
        expect(reporter_sink).not_to have_received(:publish_updates)
      end
    end

    it "skips all PR comment calls on a clean run when commenting is disabled", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        with_env("GITHUB_OUTPUT" => output_path, "GITHUB_STEP_SUMMARY" => summary_path) do
          action.send(:report, [], nil, comment: false, comment_on_success: true)
        end

        expect(File.read(summary_path)).to include("All SPM dependencies are up to date.")
        expect(reporter_sink).not_to have_received(:publish_success)
        expect(reporter_sink).not_to have_received(:clear)
        expect(reporter_sink).not_to have_received(:publish_updates)
      end
    end

    it "still publishes updates on tracking-issue runs when commenting is disabled" do
      allow(reporter_sink).to receive(:tracking_issue_run?).and_return(true)

      Dir.mktmpdir do |dir|
        with_env("GITHUB_OUTPUT" => File.join(dir, "github_output"), "GITHUB_STEP_SUMMARY" => nil) do
          action.send(:report, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil, comment: false)
        end
      end

      expect(reporter_sink).to have_received(:publish_updates)
    end

    it "still closes the tracking issue on clean tracking-issue runs when commenting is disabled" do
      allow(reporter_sink).to receive(:tracking_issue_run?).and_return(true)

      Dir.mktmpdir do |dir|
        with_env("GITHUB_OUTPUT" => File.join(dir, "github_output"), "GITHUB_STEP_SUMMARY" => nil) do
          action.send(:report, [], nil, comment: false)
        end
      end

      expect(reporter_sink).to have_received(:clear)
    end
  end

  describe "#run" do
    let(:checker_factory) { class_double(SpmChecker, new: configured_checker) }
    let(:configured_checker) { SpmChecker.new }

    it "dispatches manifest mode from environment inputs", :aggregate_failures do
      allow(configured_checker).to receive(:check_manifests).and_return([])
      allow(configured_checker).to receive(:check_for_updates)

      with_env(
        input_env(
          "INPUT_PACKAGE_MANIFEST_PATHS" => "Modules/Package.swift\nBuildTools/Package.swift",
          "INPUT_PACKAGE_RESOLVED_PATHS" => "Modules/Package.resolved\nBuildTools/Package.resolved",
          "INPUT_ALLOW_HOSTS" => "github.com",
          "SPM_VERSION_UPDATES_TAG_CACHE_DIR" => "/tmp/spm-tags"
        )
      ) do
        action.run
      end

      expect(configured_checker).to have_received(:check_manifests).with(
        ["Modules/Package.swift", "BuildTools/Package.swift"],
        ["Modules/Package.resolved", "BuildTools/Package.resolved"]
      )
      expect(configured_checker.allow_hosts).to eq(["github.com"])
      expect(configured_checker.version_tags_cache_dir).to eq("/tmp/spm-tags")
      expect(configured_checker.version_tags_cache_ttl_seconds).to eq(21_600)
      expect(configured_checker).not_to have_received(:check_for_updates)
      expect(reporter_sink).to have_received(:clear)
      expect(reporter_sink).not_to have_received(:publish_success)
      expect(reporter_sink).to have_received(:configure).with(hash_including(open_tracking_issue: false))
    end

    it "dispatches Xcode mode from environment inputs", :aggregate_failures do
      allow(configured_checker).to receive(:check_for_updates).and_return([])
      allow(configured_checker).to receive(:check_manifests)

      with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj")) do
        action.run
      end

      expect(configured_checker).to have_received(:check_for_updates).with("App.xcodeproj")
      expect(configured_checker).not_to have_received(:check_manifests)
      expect(reporter_sink).to have_received(:clear)
      expect(reporter_sink).not_to have_received(:publish_success)
    end

    it "loads repo rules from the configured path", :aggregate_failures do
      allow(configured_checker).to receive(:check_for_updates).and_return([])
      allow(configured_checker).to receive(:check_manifests)

      Dir.mktmpdir do |dir|
        rules_path = File.join(dir, "repo-rules.yml")
        File.write(
          rules_path,
          <<~YAML
            repositories:
              - url: "https://github.com/acme/pkg"
                ignore-until: "2.0.0"
          YAML
        )

        with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj", "INPUT_REPO_RULES_PATH" => rules_path)) do
          action.run
        end
      end

      expect(configured_checker.repository_update_rules).to be_suppressed(
        type: "version",
        normalized_url: "github.com/acme/pkg",
        current_version: "1.0.0",
        available_version: "1.9.0"
      )
      expect(reporter_sink).to have_received(:clear)
    end

    it "posts a clean-run comment when comment-on-success is enabled", :aggregate_failures do
      allow(configured_checker).to receive(:check_for_updates).and_return([])
      allow(configured_checker).to receive(:check_manifests)

      with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj", "INPUT_COMMENT_ON_SUCCESS" => "true")) do
        action.run
      end

      expect(reporter_sink).to have_received(:publish_success)
      expect(reporter_sink).not_to have_received(:clear)
    end

    it "never touches the PR comment when comment is disabled", :aggregate_failures do
      allow(configured_checker).to receive(:check_for_updates).and_return([])
      allow(configured_checker).to receive(:check_manifests)

      with_env(
        input_env(
          "INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj",
          "INPUT_COMMENT" => "false",
          "INPUT_COMMENT_ON_SUCCESS" => "true"
        )
      ) do
        action.run
      end

      expect(reporter_sink).not_to have_received(:publish_success)
      expect(reporter_sink).not_to have_received(:clear)
      expect(reporter_sink).not_to have_received(:publish_updates)
    end

    it "writes structured output when allow-hosts blocks a lookup", :aggregate_failures do
      message = 'Repository host "metadata.internal" for a/b is not allowed by allow-hosts (allowed: github.com)'
      allow(configured_checker).to receive(:check_for_updates).and_raise(SpmChecker::DisallowedRepositoryHost, message)
      allow(configured_checker).to receive(:check_manifests)

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "github_output")
        summary_path = File.join(dir, "step_summary")

        stdout = capture_stdout do
          expect {
            with_env(
              input_env(
                "INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj",
                "GITHUB_OUTPUT" => output_path,
                "GITHUB_STEP_SUMMARY" => summary_path
              )
            ) do
              action.run
            end
          }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        end

        output = File.read(output_path)
        expect(output).to include("updates-found=0")
        expect(output).to include("major-updates-found=0")
        expect(output).to include("minor-updates-found=0")
        expect(output).to include("patch-updates-found=0")
        expect(output).to include("blocked=true")
        expect(output).to include("error-message<<")
        expect(output).to include(message)
        expect(output_json_from(output_path)).to eq([])
        expect(File.read(summary_path)).to include("Version lookup was blocked", message)
        expect(stdout).to include("::error title=SPM version check blocked::#{message}")
        expect(reporter_sink).not_to have_received(:publish_updates)
        expect(reporter_sink).not_to have_received(:publish_success)
      end
    end

    it "fails after reporting when fail-on-updates is enabled and updates are found", :aggregate_failures do
      warnings = ["Newer version of onevcat/Kingfisher: 8.0.0"]
      allow(configured_checker).to receive(:check_for_updates).and_return(warnings)

      expect {
        with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj", "INPUT_FAIL_ON_UPDATES" => "true")) do
          action.run
        end
      }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(reporter_sink).to have_received(:publish_updates).with(warnings, [])
    end

    it "fails when a semantic update meets the fail-on threshold", :aggregate_failures do
      warnings = ["Newer version of onevcat/Kingfisher: 8.0.0"]
      warning_details = [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0"
        },
      ]
      allow(configured_checker).to receive_messages(
        check_for_updates: warnings,
        warning_details:
      )

      expect {
        with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj", "INPUT_FAIL_ON" => "major")) do
          action.run
        end
      }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(reporter_sink).to have_received(:publish_updates).with(warnings, warning_details)
    end

    it "does not fail when semantic updates are below the fail-on threshold", :aggregate_failures do
      warnings = ["Newer version of onevcat/Kingfisher: 7.1.0"]
      warning_details = [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "7.1.0"
        },
      ]
      allow(configured_checker).to receive_messages(
        check_for_updates: warnings,
        warning_details:
      )

      with_env(input_env("INPUT_XCODE_PROJECT_PATH" => "App.xcodeproj", "INPUT_FAIL_ON" => "major")) do
        action.run
      end

      expect(reporter_sink).to have_received(:publish_updates).with(warnings, warning_details)
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
