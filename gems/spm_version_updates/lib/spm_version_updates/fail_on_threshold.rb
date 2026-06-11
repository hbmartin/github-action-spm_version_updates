# frozen_string_literal: true

require_relative "update_severity"

# Parses fail-on inputs and evaluates whether reported updates should fail.
module FailOnThreshold
  ANY = "any"

  def self.from_inputs(explicit_fail_on, legacy_fail_on)
    input_name, value = [
      ["fail-on", explicit_fail_on],
      ["fail-on-updates", legacy_fail_on],
      ["fail-on-updates", "false"],
    ].find { |_name, candidate| candidate }
    normalize(value, input_name)
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

  def self.normalize(value, input_name)
    normalized = value.downcase
    return nil if ["false", "none"].include?(normalized)
    return ANY if normalized == "true"
    return normalized if UpdateSeverity.threshold?(normalized)

    raise(ArgumentError, "#{input_name} must be false, true, major, minor, or patch")
  end

  def self.build_message(threshold, count)
    plural = count == 1 ? "" : "s"
    threshold_note = threshold == ANY ? "" : " #{threshold}+"
    "Found #{count}#{threshold_note} SPM dependency update#{plural}"
  end
end
