# frozen_string_literal: true

# Shared Markdown escaping helpers for action summaries and GitHub comments.
module Render
  # Small Markdown escaping and display helpers shared by renderers.
  module Markdown
    class << self
      def inline_code(value)
        text = value.to_s
        text.include?("`") ? "``#{text}``" : "`#{text}`"
      end

      def table_cell(value)
        value.to_s.gsub("|", "\\|").gsub("\n", "<br>")
      end

      def display_version(value)
        text = value.to_s
        text.match?(/\A[0-9a-f]{40}\z/i) ? text[0, 7] : text
      end
    end
  end
end
