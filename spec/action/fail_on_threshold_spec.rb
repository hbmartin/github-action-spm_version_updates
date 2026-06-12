# frozen_string_literal: true

require_relative "../../action/lib/action_reporter"
require "spm_version_updates/fail_on_threshold"

RSpec.describe FailOnThreshold do
  def reporter_double(records: [], severity_counts: UpdateSeverity.zero_counts)
    instance_double(ActionReporter, records:, severity_counts:)
  end

  describe ".from_inputs" do
    it "prefers the explicit fail-on input over the legacy fail-on-updates input" do
      expect(described_class.from_inputs("minor", "true")).to eq("minor")
    end

    it "maps legacy fail-on-updates values", :aggregate_failures do
      expect(described_class.from_inputs(nil, "true")).to eq(described_class::ANY)
      expect(described_class.from_inputs(nil, "false")).to be_nil
      expect(described_class.from_inputs(nil, "major")).to eq("major")
    end

    it "defaults to no threshold when neither input is set" do
      expect(described_class.from_inputs(nil, nil)).to be_nil
    end

    it "normalizes case and treats none as false", :aggregate_failures do
      expect(described_class.from_inputs("MAJOR", nil)).to eq("major")
      expect(described_class.from_inputs("none", nil)).to be_nil
      expect(described_class.from_inputs(nil, "TRUE")).to eq(described_class::ANY)
    end

    it "raises an error naming the offending input", :aggregate_failures do
      expect { described_class.from_inputs("bogus", nil) }
        .to raise_error(ArgumentError, /fail-on must be false, true, major, minor, or patch/)
      expect { described_class.from_inputs(nil, "bogus") }
        .to raise_error(ArgumentError, /fail-on-updates must be false, true, major, minor, or patch/)
    end
  end

  describe ".failure_message" do
    it "returns nil when no threshold is configured" do
      expect(described_class.failure_message(nil, reporter_double(records: [{ "message" => "update" }]))).to be_nil
    end

    it "counts every record for the any threshold, with pluralization", :aggregate_failures do
      one = reporter_double(records: [{ "message" => "update" }])
      two = reporter_double(records: [{ "message" => "a" }, { "message" => "b" }])

      expect(described_class.failure_message(described_class::ANY, one)).to eq("Found 1 SPM dependency update")
      expect(described_class.failure_message(described_class::ANY, two)).to eq("Found 2 SPM dependency updates")
    end

    it "counts severities at or above a semantic threshold", :aggregate_failures do
      reporter = reporter_double(severity_counts: { "major" => 1, "minor" => 2, "patch" => 3 })

      expect(described_class.failure_message("major", reporter)).to eq("Found 1 major+ SPM dependency update")
      expect(described_class.failure_message("minor", reporter)).to eq("Found 3 minor+ SPM dependency updates")
      expect(described_class.failure_message("patch", reporter)).to eq("Found 6 patch+ SPM dependency updates")
    end

    it "returns nil when nothing meets the threshold", :aggregate_failures do
      expect(described_class.failure_message(described_class::ANY, reporter_double)).to be_nil
      expect(described_class.failure_message("major", reporter_double(severity_counts: { "major" => 0, "minor" => 2, "patch" => 0 }))).to be_nil
    end
  end
end
