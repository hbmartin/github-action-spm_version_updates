# frozen_string_literal: true

require "semantic"

# Classifies semantic-version update deltas for reporting and fail thresholds.
module UpdateSeverity
  LEVELS = ["major", "minor", "patch"].freeze
  THRESHOLD_LEVELS = {
    "major" => ["major"],
    "minor" => ["major", "minor"],
    "patch" => ["major", "minor", "patch"]
  }.freeze

  def self.apply(record)
    severity = for_versions(record["current_version"], record["available_version"])
    severity ? record.merge("severity" => severity) : record
  end

  def self.for_versions(current_version, available_version)
    current = parse_version(current_version)
    available = parse_version(available_version)
    return nil unless current && available && available > current
    return "major" unless available.major == current.major
    return "minor" unless available.minor == current.minor

    "patch"
  end

  def self.counts(records)
    records.each_with_object(zero_counts) { |record, result|
      severity = record["severity"]
      result[severity] += 1 if result.key?(severity)
    }
  end

  def self.count_at_or_above(counts, threshold)
    Array(THRESHOLD_LEVELS[threshold]).sum { |severity| counts.fetch(severity, 0) }
  end

  def self.threshold?(value)
    THRESHOLD_LEVELS.key?(value)
  end

  def self.zero_counts
    LEVELS.to_h { |severity| [severity, 0] }
  end

  def self.parse_version(value)
    Semantic::Version.new(value.to_s)
  rescue ArgumentError
    nil
  end
end
