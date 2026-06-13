# frozen_string_literal: true

require "octokit"

# Fetches and renders GitHub release notes for update comments.
module ReleaseNotes
  # Fetches GitHub releases by tag with fallback, caching, and circuit breaking.
  class Fetcher
    def initialize(client, limit: 10)
      @client = client
      @limit = limit
      @cache = {}
      @disabled = false
    end

    def fetch(repository_url, version)
      return nil if @disabled || @cache.size >= @limit

      repo = github_repo(repository_url)
      return nil unless repo

      fetch_cached(repo, version.to_s)
    end

    private

    def fetch_cached(repo, version)
      @cache[[repo, version]] ||= fetch_release(repo, version)
    end

    def fetch_release(repo, version)
      release_for(repo, version) || release_for(repo, "v#{version}")
    rescue Octokit::NotFound
      nil
    rescue Octokit::Error => error
      puts("Release notes disabled after GitHub API error: #{error.message}")
      @disabled = true
      nil
    end

    def release_for(repo, tag)
      @client.release_for_tag(repo, tag)
    rescue Octokit::NotFound
      nil
    end

    def github_repo(repository_url)
      value = repository_url.to_s
      match = value.match(/\Agit@github\.com:(?<repo>[^?#]+?)(?:\.git)?\z/) ||
              value.match(%r{\Ahttps?://(?:[^@/\s]+@)?github\.com/(?<repo>[^?#]+?)(?:\.git)?\z})
      match && match[:repo]
    end
  end

  # Renders fetched release notes as collapsed Markdown details blocks.
  class Section
    LIMIT = 1_500

    def initialize(details, fetcher)
      @details = Array(details)
      @fetcher = fetcher
    end

    def markdown
      sections = @details.filter_map { |detail| release_notes_block(detail) }
      sections.join("\n\n") unless sections.empty?
    end

    private

    def release_notes_block(detail)
      release = @fetcher.fetch(value(detail, :repository_url), value(detail, :available_version))
      body = release_body(release)
      return if body.empty?

      <<~MARKDOWN.chomp
        <details>
        <summary>📝 Release notes: #{value(detail, :package)} #{value(detail, :available_version)}</summary>

        #{body}

        </details>
      MARKDOWN
    end

    def release_body(release)
      body = value(release, :body).to_s
      body = "#{body[0, LIMIT]}…" if body.length > LIMIT
      body.gsub(/@(\w)/, '@​\1')
    end

    def value(object, key)
      object.respond_to?(:[]) ? object[key] || object[key.to_s] : nil
    end
  end
end
