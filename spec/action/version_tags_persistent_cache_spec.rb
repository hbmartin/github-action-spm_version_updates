# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../../lib/version_tags_persistent_cache"

RSpec.describe VersionTagsPersistentCache do
  def versions(*strings)
    strings.map { |string| SpmVersionUpdates::Semver.new(string) }
  end

  def cache_record(tags:, fetched_at: Time.now.utc.iso8601)
    {
      "schema_version" => described_class::SCHEMA_VERSION,
      "fetched_at" => fetched_at,
      "tags" => tags
    }
  end

  it "warns instead of raising when cache writes fail" do
    Dir.mktmpdir("version-tags-cache") do |dir|
      cache = described_class.new(directory: dir, ttl_seconds: 21_600)
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)

      expect {
        cache.write("cache-key", versions("1.0.0"))
      }.to output(/Failed to write to persistent cache/).to_stderr
    end
  end

  it "uses distinct temporary files for concurrent writes to the same cache key", :aggregate_failures do
    Dir.mktmpdir("version-tags-cache") do |dir|
      cache = described_class.new(directory: dir, ttl_seconds: 21_600)
      written_paths = Queue.new
      allow(File).to(
        receive(:write).and_wrap_original { |original, path, contents|
          written_paths << path
          original.call(path, contents)
        }
      )

      Array.new(2) {
        Thread.new { cache.write("cache-key", versions("1.1.0", "1.0.0")) }
      }.each(&:join)

      paths = Array.new(2) { written_paths.pop }
      expect(paths.uniq.size).to eq(2)
      expect(paths).to all(match(/cache-key\.json\.\d+-\d+\.tmp\z/))
      expect(File.file?(File.join(dir, "cache-key.json"))).to be(true)
      expect(Dir.children(dir).grep(/\.tmp\z/)).to be_empty
    end
  end

  it "ignores malformed fetched_at values without raising" do
    Dir.mktmpdir("version-tags-cache") do |dir|
      cache = described_class.new(directory: dir, ttl_seconds: 21_600)
      File.write(File.join(dir, "cache-key.json"), JSON.generate(cache_record(tags: ["1.0.0"], fetched_at: nil)))

      expect(cache.read("cache-key")).to be_nil
    end
  end
end
