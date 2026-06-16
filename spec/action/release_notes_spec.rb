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

    it "serves cache hits after the release lookup limit is reached", :aggregate_failures do
      allow(client).to receive(:release_for_tag).with("owner/repo", "1.2.3").and_return({ body: "notes" })

      fetcher = described_class.new(client, limit: 1)

      expect(fetcher.fetch("https://github.com/owner/repo", "1.2.3")).to eq(body: "notes")
      expect(fetcher.fetch("https://github.com/owner/repo", "1.2.3")).to eq(body: "notes")
      expect(fetcher.fetch("https://github.com/owner/other", "2.0.0")).to be_nil
      expect(client).to have_received(:release_for_tag).once
    end

    it "normalizes GitHub repository URLs with trailing slashes", :aggregate_failures do
      allow(client).to receive(:release_for_tag).with("owner/repo", "1.2.3").and_return({ body: "notes" })

      release = described_class.new(client).fetch("https://github.com/owner/repo.git/", "1.2.3")

      expect(release).to eq(body: "notes")
      expect(client).to have_received(:release_for_tag).with("owner/repo", "1.2.3")
    end

    it "skips GitHub repository URLs with query strings or fragments", :aggregate_failures do
      allow(client).to receive(:release_for_tag)

      fetcher = described_class.new(client)

      expect(fetcher.fetch("https://github.com/owner/repo.git?foo=bar", "1.2.3")).to be_nil
      expect(fetcher.fetch("git@github.com:owner/repo.git#readme", "1.2.3")).to be_nil
      expect(client).not_to have_received(:release_for_tag)
    end

    it "skips empty release versions", :aggregate_failures do
      allow(client).to receive(:release_for_tag)

      expect(described_class.new(client).fetch("https://github.com/owner/repo", "")).to be_nil
      expect(client).not_to have_received(:release_for_tag)
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
      allow(fetcher).to receive(:fetch).and_return({ body: "@team #{'a' * 1_501}" })
      details = [{ repository_url: "https://github.com/owner/repo", package: "owner/repo", available_version: "1.2.3" }]

      markdown = described_class.new(details, fetcher).markdown

      expect(markdown).to include("Release notes: owner/repo 1.2.3")
      expect(markdown).to include("…")
      expect(markdown).to include("@\u200Bteam")
      expect(markdown).not_to include("@team")
    end
  end
end
