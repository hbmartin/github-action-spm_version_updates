# frozen_string_literal: true

require_relative "../../lib/allow_host_normalizer"

RSpec.describe AllowHostNormalizer do
  describe ".normalize" do
    it "passes plain hostnames through", :aggregate_failures do
      expect(described_class.normalize("github.com")).to eq("github.com")
      expect(described_class.normalize(" gitlab.example.com ")).to eq("gitlab.example.com")
    end

    it "extracts the host from full URL entries", :aggregate_failures do
      expect(described_class.normalize("https://github.com")).to eq("github.com")
      expect(described_class.normalize("ssh://git@gitlab.com/group/repo.git")).to eq("gitlab.com")
    end

    it "lowercases and strips ports", :aggregate_failures do
      expect(described_class.normalize("GitHub.com:8443")).to eq("github.com")
      expect(described_class.normalize("https://GitHub.com:8443")).to eq("github.com")
    end

    it "falls back to the trimmed entry when host parsing fails" do
      allow(GitOperations).to receive(:host).and_return(nil)

      expect(described_class.normalize("Example.com:8443")).to eq("example.com")
    end

    it "does not trust the parsed host of a malformed scheme entry", :aggregate_failures do
      expect {
        expect(described_class.normalize("https//github.com")).to be_nil
      }.to output(/could not be parsed as a host/).to_stderr
    end

    it "warns and returns nil for unparseable entries", :aggregate_failures do
      expect {
        expect(described_class.normalize("not a host!")).to be_nil
      }.to output(/"not a host!" could not be parsed as a host/).to_stderr
    end

    it "returns nil for blank entries", :aggregate_failures do
      expect(described_class.normalize(nil)).to be_nil
      expect(described_class.normalize("")).to be_nil
      expect(described_class.normalize("   ")).to be_nil
    end
  end

  describe ".configured_entries" do
    it "strips whitespace and drops blank entries" do
      expect(described_class.configured_entries([" github.com ", "", "   ", nil, "gitlab.com"]))
        .to eq(["github.com", "gitlab.com"])
    end

    it "wraps non-array input", :aggregate_failures do
      expect(described_class.configured_entries(nil)).to eq([])
      expect(described_class.configured_entries("github.com")).to eq(["github.com"])
    end
  end
end
