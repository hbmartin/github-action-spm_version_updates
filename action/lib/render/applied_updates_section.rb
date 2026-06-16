# frozen_string_literal: true

require_relative "markdown"

module Render
  # Renders manifest rewrites performed by apply-updates mode.
  class AppliedUpdatesSection
    # One applied update table row.
    class AppliedRow
      def initialize(record)
        @record = record
      end

      def markdown
        "| #{cell('source')} | #{cell('package')} | #{Render::Markdown.table_cell(change)} |"
      end

      private

      def change
        "#{@record['current_version']} -> #{@record['available_version']}"
      end

      def cell(key)
        Render::Markdown.table_cell(@record[key])
      end
    end
    private_constant :AppliedRow

    # One skipped update summary line.
    class SkippedLine
      def initialize(record)
        @record = record
      end

      def markdown
        "- #{label}: #{@record['reason']}"
      end

      private

      def label
        @record["package"] || @record["message"]
      end
    end
    private_constant :SkippedLine

    def initialize(result)
      @result = result
    end

    def summary_lines
      return [] unless result?

      ["", "### Applied updates", "", *applied_table_lines, *skipped_lines, *failed_lines]
    end

    private

    def result?
      @result && (applied.any? || skipped.any? || failed.any?)
    end

    def applied
      Array(@result.applied)
    end

    def skipped
      Array(@result.skipped)
    end

    def failed
      Array(@result.failed)
    end

    def applied_table_lines
      return ["No manifest updates were applied."] if applied.empty?

      [
        "| Manifest | Package | Change |",
        "| --- | --- | --- |",
        *applied.map { |record| AppliedRow.new(record).markdown },
      ]
    end

    def skipped_lines
      return [] if skipped.empty?

      ["", "Skipped:", *skipped.map { |record| SkippedLine.new(record).markdown }]
    end

    def failed_lines
      return [] if failed.empty?

      ["", "Failed:", *failed.map { |record| "- `#{record[:source]}`: #{record[:error]}" }]
    end
  end
end
