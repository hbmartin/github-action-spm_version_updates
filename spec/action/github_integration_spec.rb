# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative("../../lib/github_integration")

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
  }

  describe("#post_comment") {
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
          described_class.new.post_comment("New comment body")
        end
      end

      expect(client).to(have_received(:update_comment).with("owner/repo", 123, include(described_class::COMMENT_IDENTIFIER, "New comment body")))
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
          described_class.new.post_comment("Fresh comment")
        end
      end

      expect(client).to(have_received(:add_comment)) do |repo, pr_number, body|
        expect(repo).to(eq("owner/repo"))
        expect(pr_number).to(eq(42))
        expect(body).to(include(described_class::COMMENT_IDENTIFIER, "Fresh comment"))
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
            described_class.new.post_comment("Recovered comment")
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
            described_class.new.post_comment("Updated comment")
          end
        end

        expect(stdout).to(include("Error updating comment"))
      end

      expect(client).to(have_received(:update_comment))
      expect(client).not_to(have_received(:add_comment))
    end
  }

  describe("#delete_existing_comment") {
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
          described_class.new.delete_existing_comment
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
          described_class.new.delete_existing_comment
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
            described_class.new.delete_existing_comment
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
