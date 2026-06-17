# frozen_string_literal: true

require_relative "errors"
require_relative "update_severity"

# Parses fail-on inputs and evaluates whether reported updates should fail.
module FailOnThreshold
  ANY = "any"

  def self.from_input(value)
    normalize(value)
  end

  def self.failure_message(threshold, reporter)
    return nil unless threshold

    count = failure_count(threshold, reporter)
    count.positive? ? build_message(threshold, count) : nil
  end

  def self.failure_count(threshold, reporter)
    return reporter.records.size if threshold == ANY

    UpdateSeverity.count_at_or_above(reporter.severity_counts, threshold)
  end

  def self.normalize(value)
    normalized = value.to_s.strip.downcase
    return nil if ["", "false", "none"].include?(normalized)
    return ANY if ["true", ANY].include?(normalized)
    return normalized if UpdateSeverity.threshold?(normalized)

    raise(SpmVersionUpdates::ConfigurationError, "fail-on must be false, true, any, major, minor, or patch")
  end

  def self.build_message(threshold, count)
    plural = count == 1 ? "" : "s"
    threshold_note = threshold == ANY ? "" : " #{threshold}+"
    "Found #{count}#{threshold_note} SPM dependency update#{plural}"
  end
end
