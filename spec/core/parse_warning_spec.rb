# frozen_string_literal: true

require "spm_version_updates/parse_warning"

RSpec.describe ParseWarning do
  describe ".record" do
    it "builds a string-keyed record with a readable message", :aggregate_failures do
      record = described_class.record(
        reason: "unrecognized_requirement",
        source: "Modules/Package.swift",
        snippet: 'url: "https://github.com/a/b", futureRequirement: "1.0.0"'
      )

      expect(record["type"]).to eq("parse_warning")
      expect(record["reason"]).to eq("unrecognized_requirement")
      expect(record["source"]).to eq("Modules/Package.swift")
      expect(record["snippet"]).to eq('url: "https://github.com/a/b", futureRequirement: "1.0.0"')
      expect(record["message"]).to include("Modules/Package.swift", "version requirement was not recognized", "open an issue")
    end

    it "says scanning stopped for unbalanced parentheses" do
      record = described_class.record(reason: "unbalanced_parentheses", source: "Package.swift", snippet: ".package(")

      expect(record["message"]).to include("unbalanced parentheses", "remainder of this manifest was not scanned")
    end

    it "redacts credentials in the snippet", :aggregate_failures do
      record = described_class.record(
        reason: "unrecognized_requirement",
        source: "Package.swift",
        snippet: 'url: "https://user:secret@github.com/a/b", weird: "1.0.0"'
      )

      expect(record["snippet"]).to include("[REDACTED]@github.com")
      expect(record["snippet"]).not_to include("secret")
    end

    it "truncates long snippets", :aggregate_failures do
      record = described_class.record(reason: "unbalanced_parentheses", source: "Package.swift", snippet: "x" * 500)

      expect(record["snippet"].length).to eq(described_class::SNIPPET_LIMIT + 1)
      expect(record["snippet"]).to end_with("…")
    end
  end

  describe ".issue_link" do
    let(:record) {
      described_class.record(
        reason: "unrecognized_requirement",
        source: "Package.swift",
        snippet: 'url: "https://github.com/private-org/private-repo", weird: "1.0.0"'
      )
    }

    it "prefills the issue title and body", :aggregate_failures do
      link = described_class.issue_link(record)

      expect(link).to start_with("#{described_class::ISSUE_URL}?")
      expect(link).to include("title=Manifest+parse+failure%3A+unrecognized_requirement")
      expect(link).to include("body=")
    end

    it "never embeds the manifest snippet in the URL" do
      expect(described_class.issue_link(record)).not_to include("private-org", "private-repo")
    end
  end

  describe ".describe_reason" do
    it "falls back to the raw reason for unknown values" do
      expect(described_class.describe_reason({ "reason" => "mystery" })).to eq("mystery")
    end
  end
end
