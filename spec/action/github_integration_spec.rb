# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../action/lib/github_integration"

TRACKING_ISSUE_URL = "https://github.com/owner/repo/issues/7"

RSpec.describe(GithubIntegration) {
  subject(:integration) { described_class.allocate }

  def with_env(overrides)
    original = overrides.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }

    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def github_env(event_path)
    {
      "GITHUB_TOKEN" => "token",
      "GITHUB_REPOSITORY" => "owner/repo",
      "GITHUB_EVENT_PATH" => event_path
    }
  end

  def write_event_file(dir, number = 42)
    path = File.join(dir, "event.json")
    File.write(path, { "pull_request" => { "number" => number } }.to_json)
    path
  end

  describe("#build_warnings_message") {
    it("groups duplicate package updates and includes version and GitHub links", :aggregate_failures) do
      warnings = [
        "Newer version of onevcat/Kingfisher: 8.0.0\nSource: Modules/Package.swift",
        "Newer version of onevcat/Kingfisher: 8.0.0\nSource: Features/Package.swift",
      ]
      details = [
        {
          type: "version",
          package: "onevcat/Kingfisher",
          normalized_url: "github.com/onevcat/Kingfisher",
          repository_url: "https://github.com/onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0",
          source: "Modules/Package.swift",
          note: "up to next major"
        },
        {
          type: "version",
          package: "onevcat/Kingfisher",
          normalized_url: "github.com/onevcat/Kingfisher",
          repository_url: "https://github.com/onevcat/Kingfisher",
          current_version: "7.0.0",
          available_version: "8.0.0",
          source: "Features/Package.swift",
          note: "up to next major"
        },
      ]

      message = integration.send(:build_warnings_message, warnings, details)

      expect(message).to(include("Found 1 package with potential dependency updates"))
      expect(message).to(include("| Package | Current → Available | Source | Links |"))
      expect(message.lines.grep(%r{\| `onevcat/Kingfisher` \|}).size).to(eq(1))
      expect(message).to(include("`7.0.0` → `8.0.0`"))
      expect(message).to(include("2 manifests<br>`Modules/Package.swift`<br>`Features/Package.swift`"))
      expect(message).to(include("[Compare](https://github.com/onevcat/Kingfisher/compare/7.0.0...8.0.0)"))
      expect(message).to(include("[Releases](https://github.com/onevcat/Kingfisher/releases)"))
      expect(message).not_to(include("1. Newer version"))
    end

    it("falls back to the legacy warning list without structured details", :aggregate_failures) do
      message = integration.send(:build_warnings_message, ["Newer version of onevcat/Kingfisher: 8.0.0"])

      expect(message).to(include("Found 1 potential dependency update"))
      expect(message).to(include("1. Newer version of onevcat/Kingfisher: 8.0.0"))
    end

    it("appends a parse warnings section with an open-an-issue link", :aggregate_failures) do
      parse_warnings = [
        ParseWarning.record(
          reason: "unrecognized_requirement",
          source: "Modules/Package.swift",
          snippet: 'url: "https://github.com/a/odd", futureRequirement: "1.0.0"'
        ),
      ]

      message = integration.send(
        :build_warnings_message, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil, parse_warnings
      )

      expect(message).to(include("Found 1 potential dependency update"))
      expect(message).to(include("1 declaration could not be parsed"))
      expect(message).to(include("`Modules/Package.swift`: its version requirement was not recognized"))
      expect(message).to(include('`url: "https://github.com/a/odd", futureRequirement: "1.0.0"`'))
      expect(message).to(include("[open an issue](#{ParseWarning::ISSUE_URL}?"))
    end

    it("keeps the up-to-date line when only parse warnings exist", :aggregate_failures) do
      parse_warnings = [
        ParseWarning.record(reason: "unbalanced_parentheses", source: "Package.swift", snippet: ".package("),
      ]

      message = integration.send(:build_warnings_message, [], nil, parse_warnings)

      expect(message).to(include("All SPM dependencies are up to date!"))
      expect(message).to(include("1 declaration could not be parsed"))
      expect(message).to(include("remainder of this manifest was not scanned"))
    end

    it("does not append a parse warnings section when none exist") do
      message = integration.send(:build_warnings_message, ["Newer version of onevcat/Kingfisher: 8.0.0"], nil, [])

      expect(message).not_to(include("could not be parsed"))
    end

    it("builds GitLab compare and release links for nested projects", :aggregate_failures) do
      details = [
        {
          package: "Group/Subgroup/Project",
          repository_url: "git@gitlab.com:group/subgroup/project.git",
          current_version: "1.0.0",
          available_version: "2.0.0"
        },
      ]

      message = integration.send(:build_warnings_message, ["Newer version of Group/Subgroup/Project: 2.0.0"], details)

      expect(message).to(
        include("[Compare](https://gitlab.com/group/subgroup/project/-/compare/1.0.0...2.0.0)")
      )
      expect(message).to(include("[Releases](https://gitlab.com/group/subgroup/project/-/releases)"))
      expect(message).not_to(include("N/A"))
    end

    it("uses a later credential-bearing repository URL for grouped links without leaking userinfo", :aggregate_failures) do
      warnings = [
        "Newer version of owner/repo: 1.1.0\nSource: App/Package.swift",
        "Newer version of owner/repo: 2.0.0\nSource: Tools/Package.swift",
      ]
      details = [
        {
          package: "owner/repo",
          normalized_url: "github.com/owner/repo",
          current_version: "1.0.0",
          available_version: "1.1.0",
          source: "App/Package.swift"
        },
        {
          package: "owner/repo",
          normalized_url: "github.com/owner/repo",
          repository_url: "https://token@github.com/owner/repo.git",
          current_version: "1.1.0",
          available_version: "2.0.0",
          source: "Tools/Package.swift"
        },
      ]

      message = integration.send(:build_warnings_message, warnings, details)

      expect(message).to(include("[Compare 1](https://github.com/owner/repo/compare/1.0.0...1.1.0)"))
      expect(message).to(include("[Compare 2](https://github.com/owner/repo/compare/1.1.0...2.0.0)"))
      expect(message).to(include("[Releases](https://github.com/owner/repo/releases)"))
      expect(message).not_to(include("token@"))
      expect(message).not_to(include("N/A"))
    end

    it("builds Bitbucket compare and tag links", :aggregate_failures) do
      details = [
        {
          package: "workspace/repo",
          repository_url: "https://bitbucket.org/workspace/repo.git",
          current_version: "1.0.0",
          available_version: "2.0.0"
        },
      ]

      message = integration.send(:build_warnings_message, ["Newer version of workspace/repo: 2.0.0"], details)

      expect(message).to(
        include("[Compare](https://bitbucket.org/workspace/repo/branches/compare/2.0.0..1.0.0)")
      )
      expect(message).to(include("[Tags](https://bitbucket.org/workspace/repo/downloads/?tab=tags)"))
      expect(message).not_to(include("N/A"))
    end

    it("keeps N/A links for unsupported repository hosts") do
      details = [
        {
          package: "example/repo",
          repository_url: "https://example.com/example/repo.git",
          current_version: "1.0.0",
          available_version: "2.0.0"
        },
      ]

      message = integration.send(:build_warnings_message, ["Newer version of example/repo: 2.0.0"], details)

      expect(message).to(include("| `example/repo` | `1.0.0` → `2.0.0` | Xcode project | N/A |"))
    end

    it("renders swift package update commands grouped by manifest directory", :aggregate_failures) do
      details = [
        base_detail.merge(suggested_command: "swift package update kingfisher", package_identity: "kingfisher"),
        base_detail.merge(
          package: "kean/Nuke",
          suggested_command: "swift package update nuke",
          package_identity: "nuke"
        ),
        base_detail.merge(
          package: "SwiftGen/SwiftGenPlugin",
          source: "BuildTools/Package.swift",
          suggested_command: "swift package update swiftgenplugin",
          package_identity: "swiftgenplugin"
        ),
      ]
      warnings = details.map { |detail| "Newer version of #{detail[:package]}: 8.0.0" }

      message = integration.send(:build_warnings_message, warnings, details)

      expect(message).to(include("Run in `Modules`:"))
      expect(message).to(include("swift package update kingfisher nuke"))
      expect(message).to(include("Run in `BuildTools`:"))
      expect(message).to(include("swift package update swiftgenplugin"))
      expect(message).not_to(include("To update your SPM dependencies:"))
    end

    it("labels root-level manifests as the repository root in update commands", :aggregate_failures) do
      details = [
        base_detail.merge(
          source: "Package.swift",
          suggested_command: "swift package update kingfisher",
          package_identity: "kingfisher"
        ),
      ]

      message = integration.send(:build_warnings_message, ["Newer version of onevcat/Kingfisher: 8.0.0"], details)

      expect(message).to(include("Run in the repository root:"))
      expect(message).not_to(include("Run in `.`:"))
    end

    it("skips malformed package identities when rendering update commands") do
      details = [
        base_detail.merge(suggested_command: "swift package update kingfisher", package_identity: "kingfisher"),
        base_detail.merge(package: "kean/Nuke", suggested_command: "swift package update nuke", package_identity: nil),
        base_detail.merge(package: "SwiftGen/SwiftGenPlugin", suggested_command: "swift package update swiftgenplugin", package_identity: " "),
      ]
      warnings = details.map { |detail| "Newer version of #{detail[:package]}: 8.0.0" }

      message = integration.send(:build_warnings_message, warnings, details)

      command_lines = message.lines.select { |line| line.start_with?("swift package update") }
      expect(command_lines).to(eq(["swift package update kingfisher\n"]))
    end

    it("renders manifest changes needed for out-of-range updates", :aggregate_failures) do
      details = [
        base_detail.merge(
          type: "above_maximum",
          suggested_command: "swift package update kingfisher",
          package_identity: "kingfisher",
          suggested_requirement: 'from: "8.0.0"'
        ),
      ]

      message = integration.send(:build_warnings_message, ["Newest version of onevcat/Kingfisher: 8.0.0"], details)

      expect(message).to(include("Manifest changes needed before updating:"))
      expect(message).to(include('| `onevcat/Kingfisher` | `from: "8.0.0"` | `Modules/Package.swift` |'))
    end

    it("falls back to static guidance for Xcode-mode details without commands", :aggregate_failures) do
      details = [base_detail.merge(source: nil).compact]

      message = integration.send(:build_warnings_message, ["Newer version of onevcat/Kingfisher: 8.0.0"], details)

      expect(message).to(include("To update your SPM dependencies:"))
      expect(message).not_to(include("Run in `"))
    end

    def base_detail
      {
        type: "version",
        package: "onevcat/Kingfisher",
        normalized_url: "github.com/onevcat/Kingfisher",
        repository_url: "https://github.com/onevcat/Kingfisher",
        current_version: "7.0.0",
        available_version: "8.0.0",
        source: "Modules/Package.swift"
      }
    end
  }

  describe("#publish_success") {
    it("updates the existing generated comment instead of creating a duplicate", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(receive(:issue_comments).and_return([{ id: 123, body: "#{described_class::COMMENT_IDENTIFIER}\nold" }]))
      allow(client).to(
        receive_messages(
          update_comment: { html_url: "https://github.com/owner/repo/issues/42#issuecomment-123" },
          add_comment: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.publish_success
        end
      end

      expect(client).to(
        have_received(:update_comment)
          .with("owner/repo", 123, include(described_class::COMMENT_IDENTIFIER, ReporterSink::SUCCESS_MESSAGE))
      )
      expect(client).not_to(have_received(:add_comment))
    end

    it("creates a comment when no generated comment exists", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).and_return(client))
      allow(client).to(receive(:issue_comments).and_return([{ id: 456, body: "unrelated" }]))
      allow(client).to(
        receive_messages(
          add_comment: { html_url: "https://github.com/owner/repo/issues/42#issuecomment-789" },
          update_comment: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.publish_success
        end
      end

      expect(client).to(have_received(:add_comment)) do |repo, pr_number, body|
        expect(repo).to(eq("owner/repo"))
        expect(pr_number).to(eq(42))
        expect(body).to(include(described_class::COMMENT_IDENTIFIER, ReporterSink::SUCCESS_MESSAGE))
      end
      expect(client).not_to(have_received(:update_comment))
    end

    it("falls back to create when fetching existing comments fails", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).and_return(client))
      allow(client).to(receive(:issue_comments).and_raise(Octokit::Error.new))
      allow(client).to(receive(:add_comment).and_return({ html_url: "https://github.com/owner/repo/issues/42#issuecomment-789" }))

      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_event_file(dir))) do
            described_class.new.publish_success
          end
        end

        expect(stdout).to(include("Error fetching existing comments"))
      end

      expect(client).to(have_received(:add_comment))
    end

    it("logs update failures without raising", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).and_return(client))
      allow(client).to(receive(:issue_comments).and_return([{ id: 123, body: described_class::COMMENT_IDENTIFIER }]))
      allow(client).to(receive(:update_comment).and_raise(Octokit::Error.new))
      allow(client).to(receive(:add_comment))

      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_event_file(dir))) do
            described_class.new.publish_success
          end
        end

        expect(stdout).to(include("Error updating comment"))
      end

      expect(client).to(have_received(:update_comment))
      expect(client).not_to(have_received(:add_comment))
    end
  }

  describe("#publish_updates") {
    it("publishes rendered warning details through the GitHub comment path", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(
        receive_messages(
          issue_comments: [],
          add_comment: { html_url: "https://github.com/owner/repo/issues/42#issuecomment-789" }
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).to(have_received(:add_comment)) do |_repo, _pr_number, body|
        expect(body).to(include(described_class::COMMENT_IDENTIFIER))
        expect(body).to(include("Found 1 potential dependency update"))
        expect(body).to(include("Newer version of onevcat/Kingfisher: 8.0.0"))
      end
    end

    it("posts a comment when there are only parse warnings", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(
        receive_messages(
          issue_comments: [],
          add_comment: { html_url: "https://github.com/owner/repo/issues/42#issuecomment-789" }
        )
      )
      parse_warnings = [
        ParseWarning.record(reason: "unrecognized_requirement", source: "Package.swift", snippet: "odd"),
      ]

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.publish_updates([], nil, parse_warnings)
        end
      end

      expect(client).to(have_received(:add_comment)) do |_repo, _pr_number, body|
        expect(body).to(include("All SPM dependencies are up to date!"))
        expect(body).to(include("1 declaration could not be parsed"))
      end
    end
  }

  describe("tracking-issue mode") {
    def write_schedule_event_file(dir)
      path = File.join(dir, "event.json")
      File.write(path, {}.to_json)
      path
    end

    def tracking_integration(open_tracking_issue: true)
      integration = described_class.new
      integration.configure({ open_tracking_issue: })
      integration
    end

    def stubbed_client
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      client
    end

    def issue_resource(attributes)
      Struct.new(:attributes) {
        def [](key)
          attributes[key]
        end
      }.new(attributes)
    end

    let(:issue_marker) { described_class::TrackingIssue::ISSUE_IDENTIFIER }
    let(:issue_label) { described_class::TrackingIssue::LABEL }
    let(:issue_title) { described_class::TrackingIssue::TITLE }

    it("creates a tracking issue on runs without a PR context", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          list_issues: [],
          create_issue: { number: 7, html_url: TRACKING_ISSUE_URL }
        )
      )

      integration = nil
      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          integration = tracking_integration
          integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).to(have_received(:create_issue)) do |repo, title, body, options|
        expect(repo).to(eq("owner/repo"))
        expect(title).to(eq(issue_title))
        expect(body).to(include(issue_marker, "Newer version of onevcat/Kingfisher: 8.0.0"))
        expect(options).to(eq(labels: issue_label))
      end
      expect(integration.tracking_issue_result).to(eq(number: 7, url: TRACKING_ISSUE_URL))
    end

    it("updates the existing marker-bearing issue instead of creating a duplicate", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          list_issues: [
            { number: 3, body: "human issue with the same label", pull_request: nil },
            { number: 5, body: "a PR somehow carrying the marker #{issue_marker}", pull_request: { url: "x" } },
            { number: 7, body: "#{issue_marker}\nold report", pull_request: nil },
          ],
          update_issue: { number: 7, html_url: TRACKING_ISSUE_URL },
          create_issue: nil
        )
      )

      integration = nil
      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          integration = tracking_integration
          integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).to(
        have_received(:update_issue)
          .with("owner/repo", 7, issue_title, include(issue_marker, "Newer version of onevcat/Kingfisher: 8.0.0"))
      )
      expect(client).not_to(have_received(:create_issue))
      expect(integration.tracking_issue_result).to(eq(number: 7, url: TRACKING_ISSUE_URL))
    end

    it("finds the tracking issue beyond the first page of labeled issues", :aggregate_failures) do
      client = stubbed_client
      label_squatters = Array.new(described_class::TrackingIssue::PAGE_SIZE) { |index|
        { number: index + 100, body: "human issue reusing the label", pull_request: nil }
      }
      allow(client).to(receive(:list_issues).with("owner/repo", hash_including(page: 1)).and_return(label_squatters))
      allow(client).to(
        receive(:list_issues).with("owner/repo", hash_including(page: 2))
          .and_return([{ number: 7, body: issue_marker, pull_request: nil }])
      )
      allow(client).to(receive(:update_issue).and_return({ number: 7, html_url: TRACKING_ISSUE_URL }))

      integration = nil
      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          integration = tracking_integration
          integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).to(have_received(:update_issue).with("owner/repo", 7, issue_title, anything))
      expect(integration.tracking_issue_result).to(eq(number: 7, url: TRACKING_ISSUE_URL))
    end

    it("fails closed when tracking issue lookup exhausts the pagination limit", :aggregate_failures) do
      client = stubbed_client
      label_squatters = Array.new(described_class::TrackingIssue::PAGE_SIZE) { |index|
        { number: index + 100, body: "human issue reusing the label", pull_request: nil }
      }
      allow(client).to(receive(:list_issues).and_return(label_squatters))
      allow(client).to(receive(:create_issue))

      integration = nil
      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_schedule_event_file(dir))) do
            integration = tracking_integration
            integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
          end
        end

        pages = described_class::TrackingIssue::MAX_FIND_EXISTING_PAGES
        expect(stdout).to(
          include("Error upserting tracking issue: tracking issue lookup exceeded #{pages} pages")
        )
      end

      expect(client).to(
        have_received(:list_issues).exactly(described_class::TrackingIssue::MAX_FIND_EXISTING_PAGES).times
      )
      expect(client).not_to(have_received(:create_issue))
      expect(integration.tracking_issue_result).to(be_nil)
    end

    it("does not create a duplicate tracking issue when listing existing issues fails", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(receive(:list_issues).and_raise(Octokit::Error.new))
      allow(client).to(receive(:create_issue))

      integration = nil
      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_schedule_event_file(dir))) do
            integration = tracking_integration
            integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
          end
        end

        expect(stdout).to(include("Error upserting tracking issue"))
      end

      expect(client).not_to(have_received(:create_issue))
      expect(integration.tracking_issue_result).to(be_nil)
    end

    it("closes the tracking issue with a resolution comment on clean runs", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          list_issues: [{ number: 7, body: issue_marker, pull_request: nil }],
          add_comment: nil,
          close_issue: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          tracking_integration.clear
        end
      end

      expect(client).to(
        have_received(:add_comment).with("owner/repo", 7, described_class::TRACKING_ISSUE_RESOLVED_COMMENT)
      )
      expect(client).to(have_received(:close_issue).with("owner/repo", 7))
    end

    it("closes tracking issues returned as Octokit-style resources", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          list_issues: [issue_resource(number: 7, body: issue_marker, pull_request: nil)],
          add_comment: nil,
          close_issue: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          tracking_integration.clear
        end
      end

      expect(client).to(
        have_received(:add_comment).with("owner/repo", 7, described_class::TRACKING_ISSUE_RESOLVED_COMMENT)
      )
      expect(client).to(have_received(:close_issue).with("owner/repo", 7))
    end

    it("closes the tracking issue when publish_success is used on clean runs") do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          list_issues: [{ number: 7, body: issue_marker, pull_request: nil }],
          add_comment: nil,
          close_issue: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          tracking_integration.publish_success
        end
      end

      expect(client).to(have_received(:close_issue).with("owner/repo", 7))
    end

    it("does nothing on clean runs when no tracking issue exists") do
      client = stubbed_client
      allow(client).to(receive_messages(list_issues: [], add_comment: nil, close_issue: nil))

      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          tracking_integration.clear
        end
      end

      expect(client).not_to(have_received(:close_issue))
    end

    it("stays inert on PR-less runs when open-tracking-issue is disabled", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(receive_messages(list_issues: [], create_issue: nil))

      integration = nil
      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          integration = tracking_integration(open_tracking_issue: false)
          integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).not_to(have_received(:create_issue))
      expect(integration.tracking_issue_result).to(be_nil)
    end

    it("keeps using the PR comment path when a PR context exists", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(
        receive_messages(
          issue_comments: [],
          add_comment: { html_url: "https://github.com/owner/repo/issues/42#issuecomment-789" },
          list_issues: [],
          create_issue: nil
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          tracking_integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(client).to(have_received(:add_comment))
      expect(client).not_to(have_received(:create_issue))
    end

    it("retries issue creation without labels when label creation is rejected") do
      client = stubbed_client
      allow(client).to(receive(:list_issues).and_return([]))
      allow(client).to(receive(:create_issue)) { |_repo, _title, _body, options = nil|
        raise(Octokit::UnprocessableEntity) if options

        { number: 9, html_url: "https://github.com/owner/repo/issues/9" }
      }

      integration = nil
      Dir.mktmpdir do |dir|
        with_env(github_env(write_schedule_event_file(dir))) do
          integration = tracking_integration
          integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
        end
      end

      expect(integration.tracking_issue_result).to(eq(number: 9, url: "https://github.com/owner/repo/issues/9"))
    end

    it("logs API failures without raising", :aggregate_failures) do
      client = stubbed_client
      allow(client).to(receive(:list_issues).and_return([]))
      allow(client).to(receive(:create_issue).and_raise(Octokit::Error.new))

      integration = nil
      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_schedule_event_file(dir))) do
            integration = tracking_integration
            integration.publish_updates(["Newer version of onevcat/Kingfisher: 8.0.0"])
          end
        end

        expect(stdout).to(include("Error upserting tracking issue"))
      end

      expect(integration.tracking_issue_result).to(be_nil)
    end
  }

  describe("#clear") {
    it("deletes an existing generated comment", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(
        receive_messages(
          issue_comments: [{ id: 123, body: "#{described_class::COMMENT_IDENTIFIER}\nold" }],
          delete_comment: true
        )
      )

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.clear
        end
      end

      expect(client).to(have_received(:delete_comment).with("owner/repo", 123))
    end

    it("does nothing when no generated comment exists", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(receive(:issue_comments).and_return([{ id: 456, body: "unrelated" }]))
      allow(client).to(receive(:delete_comment))

      Dir.mktmpdir do |dir|
        with_env(github_env(write_event_file(dir))) do
          described_class.new.clear
        end
      end

      expect(client).not_to(have_received(:delete_comment))
    end

    it("logs delete failures without raising", :aggregate_failures) do
      client = instance_double(Octokit::Client)
      allow(Octokit::Client).to(receive(:new).with(access_token: "token").and_return(client))
      allow(client).to(receive(:issue_comments).and_return([{ id: 123, body: described_class::COMMENT_IDENTIFIER }]))
      allow(client).to(receive(:delete_comment).and_raise(Octokit::Error.new))

      Dir.mktmpdir do |dir|
        stdout = capture_stdout do
          with_env(github_env(write_event_file(dir))) do
            described_class.new.clear
          end
        end

        expect(stdout).to(include("Error deleting comment"))
      end
    end
  }

  def capture_stdout
    original_stdout = $stdout
    captured = StringIO.new
    $stdout = captured

    yield
    captured.string
  ensure
    $stdout = original_stdout
  end
}
