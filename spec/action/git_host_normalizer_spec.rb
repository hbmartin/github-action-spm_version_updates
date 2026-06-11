# frozen_string_literal: true

require_relative "../../lib/git_host_normalizer"

RSpec.describe GitHostNormalizer do
  describe ".host" do
    it "extracts and lowercases hosts from URL remotes", :aggregate_failures do
      expect(described_class.host("https://github.com/foo/bar")).to eq("github.com")
      expect(described_class.host("ssh://git@GitHub.com/foo/bar.git")).to eq("github.com")
      expect(described_class.host("git://example.org/repo")).to eq("example.org")
    end

    it "ignores userinfo and ports", :aggregate_failures do
      expect(described_class.host("https://user:token@github.com/foo/bar")).to eq("github.com")
      expect(described_class.host("https://github.com:8443/foo/bar")).to eq("github.com")
    end

    it "extracts hosts from SCP-like remotes", :aggregate_failures do
      expect(described_class.host("git@github.com:foo/bar.git")).to eq("github.com")
      expect(described_class.host("github.com:8443/foo/bar")).to eq("github.com")
    end

    it "does not treat a colon followed by an absolute path as an SCP remote" do
      expect(described_class.host("host:/path/to/repo")).to be_nil
    end

    it "extracts bare hosts", :aggregate_failures do
      expect(described_class.host("github.com/foo/bar")).to eq("github.com")
      expect(described_class.host("gitlab.example.com")).to eq("gitlab.example.com")
    end

    it "normalizes IPv6 hosts to their canonical compressed form", :aggregate_failures do
      expect(described_class.host("https://[2001:db8::1]/org/repo.git")).to eq("2001:db8::1")
      expect(described_class.host("https://[2001:0db8:0000:0000:0000:0000:0000:0001]/org/repo")).to eq("2001:db8::1")
      expect(described_class.host("[2001:db8::1]:8443")).to eq("2001:db8::1")
      expect(described_class.host("2001:db8::1")).to eq("2001:db8::1")
    end

    it "returns nil for invalid IPv6 addresses", :aggregate_failures do
      expect(described_class.host("[not::an::address::at::all]")).to be_nil
      expect(described_class.host("[10.0.0.1]")).to be_nil
    end

    it "returns nil for blank input", :aggregate_failures do
      expect(described_class.host(nil)).to be_nil
      expect(described_class.host("")).to be_nil
      expect(described_class.host("   ")).to be_nil
    end

    it "returns nil for local paths and unparseable remotes", :aggregate_failures do
      expect(described_class.host("/abs/path")).to be_nil
      expect(described_class.host("./relative")).to be_nil
      expect(described_class.host("../relative")).to be_nil
      expect(described_class.host("file:///tmp/repo")).to be_nil
    end

    it "rejects hosts that fail the host pattern", :aggregate_failures do
      expect(described_class.host("foo_bar/baz")).to be_nil
      expect(described_class.host("foo bar/baz")).to be_nil
      expect(described_class.host("-leading.dash.com/repo")).to be_nil
    end
  end
end
