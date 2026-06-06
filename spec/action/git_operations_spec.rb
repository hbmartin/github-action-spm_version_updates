# frozen_string_literal: true

require_relative "../../lib/git_operations"

# Unit coverage for the git wrappers. These were the source of a silent bug:
# the action passed protocol-stripped URLs (e.g. "github.com/foo/bar") straight
# to `git ls-remote`, which git treats as a local path and rejects. Because the
# old implementation shelled out with backticks (capturing stdout only), the
# failure was swallowed and every lookup looked like "no versions available".
# The wrappers now run git via Open3 (no shell) and fail clearly after bounded
# non-interactive retries instead of masking lookup failures as empty results.
RSpec.describe GitOperations do
  def status(success)
    instance_double(Process::Status, success?: success)
  end

  def git_ls_remote_args(repo_url, options:, patterns: [])
    [described_class::NON_INTERACTIVE_ENV, "git", "ls-remote", *options, "--", repo_url, *patterns]
  end

  describe ".version_tags" do
    it "passes the URL to git ls-remote as a discrete non-interactive argument with tag filters" do
      allow(Open3).to receive(:capture3)
        .with(*git_ls_remote_args("https://github.com/swiftlang/swift-syntax", options: ["--tags", "--refs"], patterns: described_class::TAG_REF_PATTERNS))
        .and_return(["", "", status(true)])

      described_class.version_tags("https://github.com/swiftlang/swift-syntax")

      expect(Open3).to have_received(:capture3)
        .with(*git_ls_remote_args("https://github.com/swiftlang/swift-syntax", options: ["--tags", "--refs"], patterns: described_class::TAG_REF_PATTERNS))
    end

    it "returns the parsed tags newest-first" do
      output = "aaa\trefs/tags/1.0.0\nbbb\trefs/tags/2.1.0\nccc\trefs/tags/2.0.0\n"
      allow(Open3).to receive(:capture3).and_return([output, "", status(true)])

      expect(described_class.version_tags("https://github.com/foo/bar").map(&:to_s)).to eq(["2.1.0", "2.0.0", "1.0.0"])
    end

    it "normalizes two-component tags that SwiftPM treats as patch-zero versions" do
      output = "aaa\trefs/tags/1.0\nbbb\trefs/tags/1.1\nccc\trefs/tags/1.0.1\n"
      allow(Open3).to receive(:capture3).and_return([output, "", status(true)])

      expect(described_class.version_tags("https://github.com/foo/bar").map(&:to_s)).to eq(["1.1.0", "1.0.1", "1.0.0"])
    end

    it "normalizes v-prefixed version tags" do
      output = "aaa\trefs/tags/v1.2.3\nbbb\trefs/tags/v2.0.0-beta.1\n"
      allow(Open3).to receive(:capture3).and_return([output, "", status(true)])

      expect(described_class.version_tags("https://github.com/foo/bar").map(&:to_s)).to eq(["2.0.0-beta.1", "1.2.3"])
    end

    it "preserves build metadata in parsed tags" do
      output = "aaa\trefs/tags/1.2.3+20210102.9c8096a\nbbb\trefs/tags/1.2.4\n"
      allow(Open3).to receive(:capture3).and_return([output, "", status(true)])

      expect(described_class.version_tags("https://github.com/foo/bar").map(&:to_s)).to eq(["1.2.4", "1.2.3+20210102.9c8096a"])
    end

    it "retries, warns, and raises when git ls-remote exits non-zero", :aggregate_failures do
      allow(described_class).to receive(:sleep)
      allow(Open3).to receive(:capture3)
        .and_return(["", "fatal: 'github.com/foo/bar' does not appear to be a git repository", status(false)])

      expect { described_class.version_tags("github.com/foo/bar") }
        .to output(%r{git ls-remote failed for github\.com/foo/bar after 3 attempts}).to_stderr
        .and raise_error(described_class::LsRemoteError, /after 3 attempts/)
      expect(Open3).to have_received(:capture3).exactly(3).times
      expect(described_class).to have_received(:sleep).twice
    end

    it "runs git with a transport allowlist that blocks helper protocols", :aggregate_failures do
      allow(described_class).to receive(:sleep)
      allow(Open3).to receive(:capture3)
        .with(*git_ls_remote_args("foo://github.com/foo/bar", options: ["--tags", "--refs"], patterns: described_class::TAG_REF_PATTERNS))
        .and_return(["", "fatal: transport 'foo' not allowed", status(false)])

      expect { described_class.version_tags("foo://github.com/foo/bar") }
        .to output(/transport 'foo' not allowed/).to_stderr
        .and raise_error(described_class::LsRemoteError)
    end

    it "separates option-like repository URLs from git options", :aggregate_failures do
      allow(Open3).to receive(:capture3)
        .with(*git_ls_remote_args("--upload-pack=touch /tmp/pwned", options: ["--tags", "--refs"], patterns: described_class::TAG_REF_PATTERNS))
        .and_return(["", "", status(true)])

      described_class.version_tags("--upload-pack=touch /tmp/pwned")

      expect(Open3).to have_received(:capture3)
        .with(*git_ls_remote_args("--upload-pack=touch /tmp/pwned", options: ["--tags", "--refs"], patterns: described_class::TAG_REF_PATTERNS))
    end

    it "redacts embedded credentials from git failure warnings and errors", :aggregate_failures do
      allow(described_class).to receive(:sleep)
      allow(Open3).to receive(:capture3)
        .and_return(["", "fatal: could not read https://user:token@github.com/foo/bar", status(false)])

      expect {
        described_class.version_tags("https://user:token@github.com/foo/bar")
      }.to output(
        a_string_including(
          "failed for https://[REDACTED]@github.com/foo/bar",
          "https://[REDACTED]@github.com/foo/bar"
        ).and(not_outputting_credentials)
      ).to_stderr
        .and raise_error(described_class::LsRemoteError, not_outputting_credentials)
    end

    it "warns and raises when the git executable is missing", :aggregate_failures do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect { described_class.version_tags("https://github.com/foo/bar") }
        .to output(/git command not found/).to_stderr
        .and raise_error(described_class::LsRemoteError, /git command not found/)
    end

    it "sorts without crashing on date-style pre-release tags" do
      # swift-syntax publishes tags like 600.0.0-prerelease-2024-09-04; the
      # sort must not abort the whole list because of the zero-padded date parts.
      refs = [
        "600.0.0-prerelease-2024-08-14",
        "600.0.0-prerelease-2024-09-04",
        "510.0.1",
        "509.0.0",
      ].map { |tag| "0000000000000000000000000000000000000000\trefs/tags/#{tag}" }
        .join("\n")
      allow(Open3).to receive(:capture3).and_return([refs, "", status(true)])

      result = described_class.version_tags("https://github.com/swiftlang/swift-syntax").map(&:to_s)

      expect(result).to eq(
        [
          "600.0.0-prerelease-2024-09-04",
          "600.0.0-prerelease-2024-08-14",
          "510.0.1",
          "509.0.0",
        ]
      )
    end
  end

  describe ".branch_last_commit" do
    # Named to avoid shadowing RSpec's `output` matcher used below.
    let(:heads_output) { "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\trefs/heads/main\n" }

    it "returns the commit for the requested branch", :aggregate_failures do
      allow(Open3).to receive(:capture3).and_return([heads_output, "", status(true)])

      expect(described_class.branch_last_commit("https://github.com/foo/bar", "main"))
        .to eq("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
      expect(Open3).to have_received(:capture3)
        .with(*git_ls_remote_args("https://github.com/foo/bar", options: ["--branches"], patterns: ["refs/heads/main"]))
    end

    it "returns nil (rather than raising) when the branch is absent" do
      allow(Open3).to receive(:capture3).and_return(["", "", status(true)])

      expect(described_class.branch_last_commit("https://github.com/foo/bar", "missing")).to be_nil
    end

    it "warns and raises when git ls-remote exits non-zero", :aggregate_failures do
      allow(described_class).to receive(:sleep)
      allow(Open3).to receive(:capture3).and_return(["", "fatal: nope", status(false)])

      expect { described_class.branch_last_commit("github.com/foo/bar", "main") }
        .to output(/git ls-remote failed/).to_stderr
        .and raise_error(described_class::LsRemoteError)
    end
  end

  describe ".trim_repo_url" do
    it "strips the scheme and trailing .git, yielding a match key (not a valid remote)" do
      expect(described_class.trim_repo_url("https://github.com/foo/bar.git")).to eq("github.com/foo/bar")
    end

    it "returns an empty key for blank repository URLs", :aggregate_failures do
      expect(described_class.trim_repo_url(nil)).to eq("")
      expect(described_class.trim_repo_url("")).to eq("")
      expect(described_class.trim_repo_url("   ")).to eq("")
    end
  end

  describe ".host" do
    it "extracts normalized hostnames from common git remote forms", :aggregate_failures do
      expect(described_class.host("https://github.com/foo/bar")).to eq("github.com")
      expect(described_class.host("ssh://git@github.com/foo/bar.git")).to eq("github.com")
      expect(described_class.host("git@github.com:foo/bar.git")).to eq("github.com")
      expect(described_class.host("github.com/foo/bar")).to eq("github.com")
      expect(described_class.host("https://user:token@GitHub.com:8443/foo/bar")).to eq("github.com")
      expect(described_class.host("https://github.com@evil.com/foo/bar")).to eq("evil.com")
      expect(described_class.host("https://[2001:db8::1]/org/repo.git")).to eq("2001:db8::1")
      expect(described_class.host("[2001:db8::1]:8443")).to eq("2001:db8::1")
    end

    it "returns nil for blank, local path, and non-host remotes", :aggregate_failures do
      expect(described_class.host(nil)).to be_nil
      expect(described_class.host("")).to be_nil
      expect(described_class.host("   ")).to be_nil
      expect(described_class.host("/tmp/repo")).to be_nil
      expect(described_class.host("./repo")).to be_nil
      expect(described_class.host("../repo")).to be_nil
      expect(described_class.host("file:///tmp/repo")).to be_nil
      expect(described_class.host("ext::sh -c touch /tmp/pwned")).to be_nil
      expect(described_class.host("foo bar/baz")).to be_nil
    end

    it "returns nil for any IPAddr parsing error" do
      allow(IPAddr).to receive(:new).and_raise(IPAddr::AddressFamilyError)

      expect(described_class.host("[2001:db8::1]")).to be_nil
    end
  end

  def not_outputting_credentials
    satisfy("not output raw credentials") { |output| !output.include?("user:token") }
  end
end
