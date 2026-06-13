# frozen_string_literal: true

require "spm_version_updates/repository_link"

module Render
  # Shared repository-link rendering for step summaries and comments.
  module VersionLinks
    class << self
      def markdown_links(record, separator: "<br>")
        link = RepositoryLink.from(record["repository_url"])
        return unless link

        current, available = record.values_at("current_version", "available_version")
        return unless current && available

        link.markdown_links([{ current:, available: }], separator:)
      end
    end
  end
end
