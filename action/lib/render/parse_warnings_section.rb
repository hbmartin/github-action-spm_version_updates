# frozen_string_literal: true

require "spm_version_updates/parse_warning"

module Render
  # Unified rendering for manifest parse warnings in summaries and comments.
  class ParseWarningsSection
    def initialize(parse_warnings)
      @parse_warnings = Array(parse_warnings)
    end

    def summary_lines
      return [] if @parse_warnings.empty?

      ["", "### Parse warnings", "", *@parse_warnings.map { |record| bullet(record) }]
    end

    def comment_markdown
      return nil if @parse_warnings.empty?

      [header, "", *@parse_warnings.map { |record| bullet(record) }].join("\n")
    end

    private

    def header
      count = @parse_warnings.size
      declaration_label = count == 1 ? "declaration" : "declarations"
      "⚠️ **#{count} #{declaration_label} could not be parsed** " \
        "(updates for the affected dependencies were not checked):"
    end

    def bullet(record)
      line = "- `#{record['source']}`: #{ParseWarning.describe_reason(record)}"
      snippet = record["snippet"].to_s.delete("`")
      line << " — `#{snippet}`" unless snippet.empty?
      line << ". If this is valid Swift, please [open an issue](#{ParseWarning.issue_link(record)})."
    end
  end
end
