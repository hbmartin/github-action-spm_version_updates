# frozen_string_literal: true

require "spm_version_updates/parse_warning"

module Render
  # Unified rendering for manifest parse warnings in summaries and comments.
  class ParseWarningsSection
    # One parse warning rendered as a Markdown bullet.
    class Bullet
      def initialize(record)
        @record = record
      end

      def markdown
        "- `#{@record['source']}`: #{ParseWarning.describe_reason(@record)}" \
          "#{snippet_text}. If this is valid Swift, please [open an issue](#{ParseWarning.issue_link(@record)})."
      end

      private

      def snippet_text
        snippet = @record["snippet"].to_s.delete("`")
        snippet.empty? ? "" : " — `#{snippet}`"
      end
    end
    private_constant :Bullet

    def initialize(parse_warnings)
      @parse_warnings = Array(parse_warnings)
    end

    def summary_lines
      return [] if @parse_warnings.empty?

      ["", "### Parse warnings", "", *@parse_warnings.map { |record| Bullet.new(record).markdown }]
    end

    def comment_markdown
      return nil if @parse_warnings.empty?

      [header, "", *@parse_warnings.map { |record| Bullet.new(record).markdown }].join("\n")
    end

    private

    def header
      count = @parse_warnings.size
      declaration_label = count == 1 ? "declaration" : "declarations"
      "⚠️ **#{count} #{declaration_label} could not be parsed** " \
        "(updates for the affected dependencies were not checked):"
    end
  end
end
