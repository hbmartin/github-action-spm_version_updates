# frozen_string_literal: true

# Immutable report data shared between the action, local outputs, and sinks.
class ReportPayload
  # Normalizes caller-provided attributes into payload fields.
  class Attributes
    def initialize(raw)
      @raw = raw
    end

    def to_h
      {
        warnings: warnings,
        warning_details: warning_details,
        parse_warnings: parse_warnings,
        missing_resolved: missing_resolved,
        applied_updates: @raw[:applied_updates],
        timings: @raw[:timings]
      }
    end

    private

    def warnings
      Array(@raw[:warnings])
    end

    def warning_details
      Array(@raw[:warning_details])
    end

    def parse_warnings
      Array(@raw[:parse_warnings])
    end

    def missing_resolved
      Array(@raw[:missing_resolved])
    end
  end
  private_constant :Attributes

  def self.coerce(value, *legacy_values, **attributes)
    # Existing payloads are already normalized; keyword overrides are ignored.
    return value if value.kind_of?(self)

    warning_details, parse_warnings, missing_resolved = legacy_values
    new(
      warnings: value,
      warning_details:,
      parse_warnings:,
      missing_resolved: attributes.fetch(:missing_resolved, missing_resolved),
      applied_updates: attributes[:applied_updates],
      timings: attributes[:timings]
    )
  end

  def initialize(attributes)
    @attributes = Attributes.new(attributes).to_h
  end

  def warnings
    @attributes.fetch(:warnings)
  end

  def warning_details
    @attributes.fetch(:warning_details)
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
