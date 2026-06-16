# frozen_string_literal: true

require_relative "../../action/lib/action_reporter"
require "spm_version_updates/fail_on_threshold"

RSpec.describe FailOnThreshold do
  def reporter_double(records: [], severity_counts: UpdateSeverity.zero_counts)
    instance_double(ActionReporter, records:, severity_counts:)
  end

  describe ".from_input" do
    it "maps configured fail-on values", :aggregate_failures do
      expect(described_class.from_input("true")).to eq(described_class::ANY)
      expect(described_class.from_input("any")).to eq(described_class::ANY)
      expect(described_class.from_input("false")).to be_nil
      expect(described_class.from_input("major")).to eq("major")
    end

    it "defaults to no threshold when the input is unset" do
      expect(described_class.from_input(nil)).to be_nil
    end

    it "normalizes case and treats none as false", :aggregate_failures do
      expect(described_class.from_input("MAJOR")).to eq("major")
      expect(described_class.from_input("none")).to be_nil
      expect(described_class.from_input("TRUE")).to eq(described_class::ANY)
    end

    it "raises an error naming the offending input" do
      expect { described_class.from_input("bogus") }
        .to raise_error(ArgumentError, /fail-on must be false, true, any, major, minor, or patch/)
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
