# frozen_string_literal: true

require_relative "markdown"

module Render
  # Renders manifest rewrites performed by apply-updates mode.
  class AppliedUpdatesSection
    def initialize(result)
      @result = result
    end

    def summary_lines
      return [] unless result?

      lines = ["", "### Applied updates", ""]
      lines.concat(applied_table_lines)
      lines.concat(skipped_lines)
      lines.concat(failed_lines)
      lines
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
        *applied.map { |record|
          "| #{cell(record['source'])} | #{cell(record['package'])} | #{cell(change(record))} |"
        },
      ]
    end

    def skipped_lines
      return [] if skipped.empty?

      ["", "Skipped:", *skipped.map { |record| "- #{record['package'] || record['message']}: #{record['reason']}" }]
    end

    def failed_lines
      return [] if failed.empty?

      ["", "Failed:", *failed.map { |record| "- `#{record[:source]}`: #{record[:error]}" }]
    end

    def change(record)
      "#{record['current_version']} -> #{record['available_version']}"
    end

    def cell(value)
      Render::Markdown.table_cell(value)
    end
  end
end
