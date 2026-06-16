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

  # Normalized update record with eligibility rules for apply-updates mode.
  class Record
    def initialize(attributes)
      @attributes = attributes.to_h.transform_keys(&:to_s)
    end

    def eligible?
      !skip_reason
    end

    def source
      @attributes["source"]
    end

    def to_h
      @attributes
    end

    def skipped_entry
      @attributes.merge("reason" => skip_reason)
    end

    private

    def skip_reason
      type = @attributes["type"]
      return "no-source" if @attributes["source"].to_s.empty?
      return "above-maximum" if type == "above_maximum"
      return type if %w(branch revision).include?(type)

      "unsupported" unless type == "version"
    end
  end
  private_constant :Record

  # Eligible and skipped records after applying manifest rewrite rules.
  class ClassifiedRecords
    attr_reader :eligible, :skipped

    def initialize(records)
      @eligible = []
      @skipped = []
      records.each { |record| classify(record) }
    end

    private

    def classify(record)
      record.eligible? ? @eligible << record : @skipped << record.skipped_entry
    end
  end
  private_constant :ClassifiedRecords

  # Applies eligible records one manifest file at a time.
  class BatchApplier
    def initialize(records, updater)
      @records = records
      @updater = updater
      @result = { applied: [], skipped: [], failed: [] }
    end

    def result_with(skipped)
      records_by_source.each { |source, records| apply_source(source, records) }
      Result.new(applied: @result[:applied], skipped: skipped + @result[:skipped], failed: @result[:failed])
    end

    private

    def records_by_source
      @records.group_by(&:source)
    end

    def apply_source(source, records)
      result = @updater.update_file(source, records.map(&:to_h))
      @result[:applied].concat(result.applied)
      @result[:skipped].concat(result.skipped)
    rescue StandardError => error
      @result[:failed] << { source:, error: error.message }
    end
  end
  private_constant :BatchApplier

  def initialize(records, updater: ManifestUpdater)
    @records = Array(records).map { |record| Record.new(record) }
    @updater = updater
  end

  def apply
    classified = ClassifiedRecords.new(@records)
    BatchApplier.new(classified.eligible, @updater).result_with(classified.skipped)
  end
end
