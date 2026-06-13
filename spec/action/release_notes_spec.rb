# frozen_string_literal: true

require_relative "../../action/lib/release_notes"

RSpec.describe ReleaseNotes do
  describe ReleaseNotes::Fetcher do
    let(:client) { instance_double(Octokit::Client) }

    it "fetches GitHub releases by tag and falls back to v-prefixed tags" do
      allow(client).to receive(:release_for_tag).with("owner/repo", "1.2.3").and_raise(Octokit::NotFound)
      allow(client).to receive(:release_for_tag).with("owner/repo", "v1.2.3").and_return({ body: "notes" })

      release = described_class.new(client).fetch("https://github.com/owner/repo.git", "1.2.3")

      expect(release).to eq(body: "notes")
    end

    it "skips non-GitHub repositories", :aggregate_failures do
      allow(client).to receive(:release_for_tag)

      expect(described_class.new(client).fetch("https://gitlab.com/owner/repo", "1.2.3")).to be_nil
      expect(client).not_to have_received(:release_for_tag)
    end

    it "circuit-breaks after non-404 Octokit errors", :aggregate_failures do
      allow(client).to receive(:release_for_tag).and_raise(Octokit::Error.new)

      fetcher = described_class.new(client)
      expect(fetcher.fetch("https://github.com/owner/repo", "1.2.3")).to be_nil
      expect(fetcher.fetch("https://github.com/owner/repo", "1.2.4")).to be_nil
      expect(client).to have_received(:release_for_tag).once
    end
  end

  describe ReleaseNotes::Section do
    it "renders truncated release notes and neutralizes mentions", :aggregate_failures do
      fetcher = instance_double(ReleaseNotes::Fetcher)
      allow(fetcher).to receive(:fetch).and_return({ body: "#{'a' * 1_501} @team" })
      details = [{ repository_url: "https://github.com/owner/repo", package: "owner/repo", available_version: "1.2.3" }]

      markdown = described_class.new(details, fetcher).markdown

      expect(markdown).to include("Release notes: owner/repo 1.2.3")
      expect(markdown).to include("…")
      expect(markdown).not_to include("@team")
    end
  end
end
