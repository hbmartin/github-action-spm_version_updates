# frozen_string_literal: true

# Immutable report data shared between the action, local outputs, and sinks.
class ReportPayload
  attr_reader :updates, :parse_warnings, :missing_resolved, :applied_updates, :timings

  def initialize(updates:, parse_warnings: [], missing_resolved: [], applied_updates: nil, timings: nil)
    @updates = records(updates)
    @parse_warnings = records(parse_warnings)
    @missing_resolved = records(missing_resolved)
    @applied_updates = applied_updates
    @timings = timings
  end

  private

  def records(values)
    Array(values).map { |record| record.to_h.transform_keys(&:to_s).compact }
  end
end
