# frozen_string_literal: true

module Render
  # Renders missing Package.resolved files that were allowed to degrade.
  class MissingResolvedSection
    def initialize(records)
      @records = Array(records)
    end

    def summary_lines
      return [] if @records.empty?

      ["", "### Missing Package.resolved", "", *@records.map { |record| "- `#{record['source']}`: #{record['message']}" }, "", resolve_hint]
    end

    def comment_markdown
      return nil if @records.empty?

      ["### Missing Package.resolved", "", *@records.map { |record| "- `#{record['source']}`: #{record['message']}" }, "", resolve_hint].join("\n")
    end

    private

    def resolve_hint
      "Run `swift package resolve` and commit the generated Package.resolved file to enable update checks for those manifests."
    end
  end
end
