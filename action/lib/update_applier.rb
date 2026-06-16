# frozen_string_literal: true

require "spm_version_updates/manifest_updater"

# Applies manifest update records to Package.swift files in the workspace.
class UpdateApplier
  # Summary of manifest rewrites attempted by apply-updates mode.
  Result = Struct.new(:applied, :skipped, :failed, keyword_init: true) {
    def applied_count
      applied.size
    end

    def failed?
      failed.any?
    end

    def to_json_records
      applied
    end
  }

  def initialize(records, updater: ManifestUpdater)
    @records = Array(records).map { |record| stringify(record) }
    @updater = updater
  end

  def apply
    eligible, skipped = classify_records
    failed = []
    applied = apply_eligible_records(eligible, skipped, failed)
    Result.new(applied:, skipped:, failed:)
  end

  private

  def apply_eligible_records(eligible, skipped, failed)
    applied = []
    records_by_source(eligible).each { |source, records|
      begin
        result = @updater.update_file(source, records)
        applied.concat(result.applied)
        skipped.concat(result.skipped)
      rescue StandardError => error
        failed << { source:, error: error.message }
      end
    }
    applied
  end

  def records_by_source(records)
    records.group_by { |record| record["source"] }
  end

  def classify_records
    @records.each_with_object([[], []]) { |record, groups|
      reason = skip_reason(record)
      reason ? groups.last << record.merge("reason" => reason) : groups.first << record
    }
  end

  def skip_reason(record)
    type = record["type"]
    return "no-source" if record["source"].to_s.empty?
    return "above-maximum" if type == "above_maximum"
    return type if %w(branch revision).include?(type)

    "unsupported" unless type == "version"
  end

  def stringify(record)
    record.to_h.transform_keys(&:to_s)
  end
end
