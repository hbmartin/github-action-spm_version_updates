# frozen_string_literal: true

# Immutable report data shared between the action, local outputs, and sinks.
class ReportPayload
  # Normalizes caller-provided attributes into payload fields.
  class Attributes
    def initialize(updates:, parse_warnings:, missing_resolved:, applied_updates:, timings:)
      @updates = updates
      @parse_warnings = parse_warnings
      @missing_resolved = missing_resolved
      @applied_updates = applied_updates
      @timings = timings
    end

    def to_h
      {
        updates: records(@updates),
        parse_warnings: parse_warnings,
        missing_resolved: missing_resolved,
        applied_updates: @applied_updates,
        timings: @timings
      }
    end

    private

    def parse_warnings
      records(@parse_warnings)
    end

    def missing_resolved
      records(@missing_resolved)
    end

    def records(values)
      Array(values).map { |record| record.to_h.transform_keys(&:to_s).compact }
    end
  end
  private_constant :Attributes

  def initialize(updates:, parse_warnings: [], missing_resolved: [], applied_updates: nil, timings: nil)
    @attributes = Attributes.new(
      updates:,
      parse_warnings:,
      missing_resolved:,
      applied_updates:,
      timings:
    ).to_h
  end

  def updates
    @attributes.fetch(:updates)
  end

  def parse_warnings
    @attributes.fetch(:parse_warnings)
  end

  def missing_resolved
    @attributes.fetch(:missing_resolved)
  end

  def applied_updates
    @attributes.fetch(:applied_updates)
  end

  def timings
    @attributes.fetch(:timings)
  end
end
