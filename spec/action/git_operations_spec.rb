# frozen_string_literal: true

require_relative "../../lib/git_operations"

# Unit coverage for the git wrappers. These were the source of a silent bug:
# the action passed protocol-stripped URLs (e.g. "github.com/foo/bar") straight
# to `git ls-remote`, which git treats as a local path and rejects. Because the
# old implementation shelled out with backticks (capturing stdout only), the
# failure was swallowed and every lookup looked like "no versions available".
# The wrappers now run git via Open3 (no shell) and surface a clear warning on a
# non-zero exit instead of masking it as an empty result.
RSpec.describe GitOperations do
  def status(success)
    instance_double(Process::Status, success?: success)
  end

  describe ".version_tags" do
    it "passes the URL to git ls-remote as a discrete argument (never through a shell)" do
      expect(Open3).to receive(:capture3)
        .with("git", "ls-remote", "-t", "https://github.com/swiftlang/swift-syntax")
        .and_return(["", "", status(true)])

      described_class.version_tags("https://github.com/swiftlang/swift-syntax")
    end

    it "returns the parsed tags newest-first" do
      output = "aaa\trefs/tags/1.0.0\nbbb\trefs/tags/2.1.0\nccc\trefs/tags/2.0.0\n"
      allow(Open3).to receive(:capture3).and_return([output, "", status(true)])

      expect(described_class.version_tags("https://github.com/foo/bar").map(&:to_s)).to eq(["2.1.0", "2.0.0", "1.0.0"])
    end

    it "warns and returns [] when git ls-remote exits non-zero" do
      allow(Open3).to receive(:capture3)
        .and_return(["", "fatal: 'github.com/foo/bar' does not appear to be a git repository", status(false)])

      result = nil
      expect { result = described_class.version_tags("github.com/foo/bar") }
        .to output(%r{git ls-remote .* failed for github\.com/foo/bar}).to_stderr
      expect(result).to eq([])
    end

    it "sorts without crashing on pre-release tags the semantic gem mishandles" do
      # swift-syntax publishes tags like 600.0.0-prerelease-2024-09-04; the
      # `semantic` gem raises Integer("09") when comparing two of these. The sort
      # must not abort the whole list because of them.
      refs = [
        "600.0.0-prerelease-2024-08-14",
        "600.0.0-prerelease-2024-09-04",
        "510.0.1",
        "509.0.0",
      ].map { |tag| "0000000000000000000000000000000000000000\trefs/tags/#{tag}" }.join("\n")
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
    let(:heads_output) { "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\trefs/heads/main\ncafecafe\trefs/heads/dev\n" }

    it "returns the commit for the requested branch" do
      allow(Open3).to receive(:capture3).and_return([heads_output, "", status(true)])

      expect(described_class.branch_last_commit("https://github.com/foo/bar", "main"))
        .to eq("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
    end

    it "returns nil (rather than raising) when the branch is absent" do
      allow(Open3).to receive(:capture3).and_return([heads_output, "", status(true)])

      expect(described_class.branch_last_commit("https://github.com/foo/bar", "missing")).to be_nil
    end

    it "warns and returns nil when git ls-remote exits non-zero" do
      allow(Open3).to receive(:capture3).and_return(["", "fatal: nope", status(false)])

      result = "unset"
      expect { result = described_class.branch_last_commit("github.com/foo/bar", "main") }
        .to output(/git ls-remote .* failed/).to_stderr
      expect(result).to be_nil
    end
  end

  describe ".trim_repo_url" do
    it "strips the scheme and trailing .git, yielding a match key (not a valid remote)" do
      expect(described_class.trim_repo_url("https://github.com/foo/bar.git")).to eq("github.com/foo/bar")
    end
  end
end
