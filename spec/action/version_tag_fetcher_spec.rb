# frozen_string_literal: true

require_relative "../../lib/version_tag_fetcher"

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
end
