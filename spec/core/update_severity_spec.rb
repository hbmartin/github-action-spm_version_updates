# frozen_string_literal: true

require "spm_version_updates/update_severity"

RSpec.describe UpdateSeverity do
  describe ".for_versions" do
    it "classifies the numeric delta between versions", :aggregate_failures do
      expect(described_class.for_versions("1.0.0", "2.0.0")).to eq("major")
      expect(described_class.for_versions("1.0.0", "1.2.0")).to eq("minor")
      expect(described_class.for_versions("1.2.3", "1.2.4")).to eq("patch")
    end

    it "returns nil when the available version is not newer", :aggregate_failures do
      expect(described_class.for_versions("1.2.3", "1.2.3")).to be_nil
      expect(described_class.for_versions("2.0.0", "1.9.9")).to be_nil
    end

    it "returns nil when either side is not a semantic version", :aggregate_failures do
      expect(described_class.for_versions("main", "1.0.0")).to be_nil
      expect(described_class.for_versions("1.0.0", "not-a-version")).to be_nil
      expect(described_class.for_versions(nil, "1.0.0")).to be_nil
    end

    it "normalizes v-prefixed and two-component versions", :aggregate_failures do
      expect(described_class.for_versions("v1.2.0", "v1.3.0")).to eq("minor")
      expect(described_class.for_versions("1.2", "1.2.1")).to eq("patch")
    end
  end

  describe ".apply" do
    it "merges a severity into semantic update records", :aggregate_failures do
      record = { "type" => "version", "current_version" => "1.0.0", "available_version" => "2.0.0" }

      expect(described_class.apply(record)).to eq(record.merge("severity" => "major"))
      expect(described_class.apply(record.merge("type" => "above_maximum"))["severity"]).to eq("major")
    end

    it "treats a missing type as a semantic update record" do
      record = { "current_version" => "1.0.0", "available_version" => "1.0.1" }

      expect(described_class.apply(record)["severity"]).to eq("patch")
    end

    it "returns branch and revision records untouched", :aggregate_failures do
      branch_record = { "type" => "branch", "current_version" => "1.0.0", "available_version" => "2.0.0" }
      revision_record = branch_record.merge("type" => "revision")

      expect(described_class.apply(branch_record)).to eq(branch_record)
      expect(described_class.apply(revision_record)).to eq(revision_record)
    end

    it "returns the record unchanged when no severity can be derived" do
      record = { "type" => "version", "current_version" => "main", "available_version" => "2.0.0" }

      expect(described_class.apply(record)).to eq(record)
    end

    it "does not mutate the input record" do
      record = { "type" => "version", "current_version" => "1.0.0", "available_version" => "2.0.0" }

      described_class.apply(record)

      expect(record).not_to have_key("severity")
    end
  end

  describe ".counts" do
    it "tallies only known severities", :aggregate_failures do
      records = [
        { "severity" => "major" },
        { "severity" => "minor" },
        { "severity" => "minor" },
        { "severity" => "bogus" },
        { "message" => "no severity" },
      ]

      expect(described_class.counts(records)).to eq("major" => 1, "minor" => 2, "patch" => 0)
      expect(described_class.counts([])).to eq("major" => 0, "minor" => 0, "patch" => 0)
    end
  end

  describe ".count_at_or_above" do
    let(:counts) { { "major" => 2, "minor" => 3, "patch" => 4 } }

    it "cascades counts down from the requested threshold", :aggregate_failures do
      expect(described_class.count_at_or_above(counts, "major")).to eq(2)
      expect(described_class.count_at_or_above(counts, "minor")).to eq(5)
      expect(described_class.count_at_or_above(counts, "patch")).to eq(9)
    end

    it "returns zero for unknown thresholds", :aggregate_failures do
      expect(described_class.count_at_or_above(counts, "any")).to eq(0)
      expect(described_class.count_at_or_above(counts, nil)).to eq(0)
    end
  end

  describe ".threshold?" do
    it "accepts only the severity level names", :aggregate_failures do
      expect(described_class.threshold?("major")).to be(true)
      expect(described_class.threshold?("minor")).to be(true)
      expect(described_class.threshold?("patch")).to be(true)
      expect(described_class.threshold?("any")).to be(false)
      expect(described_class.threshold?("true")).to be(false)
      expect(described_class.threshold?("")).to be(false)
    end
  end
end
