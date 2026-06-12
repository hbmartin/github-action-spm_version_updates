# frozen_string_literal: true

require "spm_version_updates/version_tag_fetcher"

RSpec.describe VersionTagFetcher do
  it "preserves the first lookup failure backtrace and cause when aggregating errors", :aggregate_failures do
    original_error = GitOperations::LsRemoteError.new("git ls-remote failed for https://github.com/acme/one")
    original_error.set_backtrace(["git_operations.rb:123"])
    allow(GitOperations).to receive(:version_tags).and_raise(original_error)

    expect {
      described_class.call(
        [["cache-key", "https://github.com/acme/one", "persistent-key"]],
        worker_limit: 1
      )
    }.to raise_error(GitOperations::LsRemoteError) { |error|
      expect(error.message).to eq("git ls-remote failed for https://github.com/acme/one")
      expect(error.backtrace).to eq(["git_operations.rb:123"])
      expect(error.cause).to equal(original_error)
    }
  end

  it "returns results and errors keyed by cache key when raise_on_error is false", :aggregate_failures do
    failure = GitOperations::LsRemoteError.new("git ls-remote failed for https://github.com/acme/bad")
    allow(GitOperations).to receive(:version_tags).with("https://github.com/acme/bad").and_raise(failure)
    allow(GitOperations).to receive(:version_tags).with("https://github.com/acme/good").and_return(["1.0.0"])

    results, errors = described_class.call(
      [
        ["bad-key", "https://github.com/acme/bad", "bad-persistent-key"],
        ["good-key", "https://github.com/acme/good", "good-persistent-key"],
      ],
      worker_limit: 1,
      raise_on_error: false
    )

    expect(results).to eq("good-key" => ["1.0.0"])
    expect(errors).to eq("bad-key" => failure)
  end

  it "returns results and empty errors on success" do
    allow(GitOperations).to receive(:version_tags).and_return(["1.0.0"])

    results, errors = described_class.call(
      [["cache-key", "https://github.com/acme/one", "persistent-key"]],
      worker_limit: 1
    )

    expect([results, errors]).to eq([{ "cache-key" => ["1.0.0"] }, {}])
  end
end
