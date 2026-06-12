# frozen_string_literal: true

require_relative "git_host_normalizer"
require_relative "git_operations"

# Normalizes user-provided allow-host entries into hostnames.
# @api private
class AllowHostNormalizer
  MALFORMED_SCHEME_PATTERN = %r{\A[a-z][a-z0-9+\-.]*//}i

  def self.normalize(entry)
    new(entry).normalize
  end

  def self.configured_entries(entries)
    Array(entries).filter_map { |entry|
      value = entry.to_s.strip
      value unless value.empty?
    }
  end

  def initialize(entry)
    @raw = entry.to_s.strip
  end

  def normalize
    return nil if raw.empty?
    return parsed if parsed && !malformed_scheme?
    return fallback if fallback.match?(GitHostNormalizer::HOST_PATTERN)

    warn_unparseable
    nil
  end

  private

  attr_reader :raw

  def parsed
    @parsed ||= GitOperations.host(raw)
  end

  def fallback
    @fallback ||= raw.sub(/:\d+\z/, "").downcase
  end

  def malformed_scheme?
    raw.match?(MALFORMED_SCHEME_PATTERN)
  end

  def warn_unparseable
    warn("allow-hosts entry #{raw.inspect} could not be parsed as a host and will not match any repository URL")
  end
end
