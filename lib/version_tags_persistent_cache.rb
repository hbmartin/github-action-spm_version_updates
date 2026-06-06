# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "credential_redactor"
require_relative "spm_version_updates/semver"

# Persistent on-disk cache for successful git tag lookups restored by actions/cache.
class VersionTagsPersistentCache
  DEFAULT_TTL_SECONDS = 21_600
  SCHEMA_VERSION = 1

  def self.cache_key(normalized_url, repository_url)
    Digest::SHA256.hexdigest("#{normalized_url}\n#{CredentialRedactor.redact(repository_url)}")
  end

  def initialize(directory:, ttl_seconds:, clock: -> { Time.now.utc })
    @directory = directory.to_s
    @ttl_seconds = ttl_seconds.to_i
    @clock = clock
  end

  def enabled?
    !@directory.empty? && @ttl_seconds.positive?
  end

  def read(cache_key)
    return nil unless enabled?

    record = read_record(cache_key)
    return nil unless fresh_record?(record)

    versions_from(record)
  end

  def write(cache_key, versions)
    return unless enabled?

    temp = temp_path(cache_key)
    FileUtils.mkdir_p(@directory)
    File.write(temp, JSON.pretty_generate(record_for(versions)))
    File.rename(temp, path_for(cache_key))
  end

  private

  def read_record(cache_key)
    JSON.parse(File.read(path_for(cache_key)))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def fresh_record?(record)
    return false unless record && record["schema_version"] == SCHEMA_VERSION

    fetched_at = Time.iso8601(record.fetch("fetched_at"))
    (@clock.call - fetched_at) <= @ttl_seconds
  rescue ArgumentError, KeyError
    false
  end

  def versions_from(record)
    Array(record["tags"]).filter_map { |tag|
      begin
        SpmVersionUpdates::Semver.new(tag)
      rescue ArgumentError
        nil
      end
    }
      .sort
      .reverse
  end

  def record_for(versions)
    {
      "schema_version" => SCHEMA_VERSION,
      "fetched_at" => @clock.call.iso8601,
      "tags" => versions.map(&:to_s)
    }
  end

  def path_for(cache_key)
    File.join(@directory, "#{cache_key}.json")
  end

  def temp_path(cache_key)
    "#{path_for(cache_key)}.tmp"
  end
end
