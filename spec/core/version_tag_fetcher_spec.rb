# frozen_string_literal: true

require "spm_version_updates/version_tag_fetcher"

RSpec.describe VersionTagFetcher do
  let(:deterministic_sleep) { ->(index) { [0.001, 0.003, 0.002, 0.005, 0.001][index % 5] } }

  def lookup(index)
    ["key-#{index}", "https://github.com/acme/repo-#{index}", "persistent-#{index}"]
  end

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

  it "keeps concurrent lookups keyed correctly while respecting the worker limit", :aggregate_failures do
    mutex = Mutex.new
    active = 0
    max_active = 0
    allow(GitOperations).to receive(:version_tags) { |url|
      begin
        index = url[/repo-(\d+)/, 1].to_i
        mutex.synchronize {
          active += 1
          max_active = [max_active, active].max
        }
        sleep(deterministic_sleep.call(index))
        ["#{index}.0.0"]
      ensure
        mutex.synchronize { active -= 1 }
      end
    }

    results, errors = described_class.call(Array.new(60) { |index| lookup(index) }, worker_limit: 4)

    expect(errors).to eq({})
    expect(results).to eq((0...60).to_h { |index| ["key-#{index}", ["#{index}.0.0"]] })
    expect(max_active).to be <= 4
  end

  it "does not create more workers than lookups" do
    mutex = Mutex.new
    active = 0
    max_active = 0
    allow(GitOperations).to receive(:version_tags) {
      begin
        mutex.synchronize {
          active += 1
          max_active = [max_active, active].max
        }
        sleep(0.002)
        ["1.0.0"]
      ensure
        mutex.synchronize { active -= 1 }
      end
    }

    described_class.call(Array.new(3) { |index| lookup(index) }, worker_limit: 10)

    expect(max_active).to be <= 3
  end

  it "keeps result and error keys disjoint when some concurrent lookups fail", :aggregate_failures do
    mutex = Mutex.new
    active = 0
    max_active = 0
    allow(GitOperations).to receive(:version_tags) { |url|
      begin
        index = url[/repo-(\d+)/, 1].to_i
        mutex.synchronize {
          active += 1
          max_active = [max_active, active].max
        }
        sleep(deterministic_sleep.call(index))
        raise(GitOperations::LsRemoteError, "failed #{index}") if (index % 5).zero?

        ["#{index}.0.0"]
      ensure
        mutex.synchronize { active -= 1 }
      end
    }

    results, errors = described_class.call(
      Array.new(40) { |index| lookup(index) },
      worker_limit: 4,
      raise_on_error: false
    )

    expect(results.keys | errors.keys).to match_array((0...40).map { |index| "key-#{index}" })
    expect(results.keys & errors.keys).to eq([])
    expect(max_active).to be <= 4
  end

  it "returns empty result and error hashes for zero lookups" do
    expect(described_class.call([], worker_limit: 4)).to eq([{}, {}])
  end
end
