# frozen_string_literal: true

require "octokit"

# Fetches and renders GitHub release notes for update comments.
module ReleaseNotes
  # Normalized GitHub release lookup request.
  class Lookup
    def initialize(repository_url, version)
      @repository = Repository.new(repository_url)
      @version = version.to_s.strip
    end

    def valid?
      @repository.github? && !@version.empty?
    end

    def key
      [repository_name, @version]
    end

    def repository_name
      @repository.name
    end

    def tags
      [@version, "v#{@version}"]
    end
  end
  private_constant :Lookup

  # Extracts owner/repo from supported GitHub remote URL forms.
  class Repository
    def initialize(url)
      @url = url.to_s
    end

    def github?
      name
    end

    def name
      @name ||= ssh_name || https_name
    end

    private

    def ssh_name
      @url.match(%r{\Agit@github\.com:(?<repo>[^/?#\s]+/[^/?#\s]+?)(?:\.git)?/*\z})&.[](:repo)
    end

    def https_name
      @url.match(%r{\Ahttps?://(?:[^@/\s]+@)?github\.com/(?<repo>[^/?#\s]+/[^/?#\s]+?)(?:\.git)?/*\z})&.[](:repo)
    end
  end
  private_constant :Repository

  # Fetches GitHub releases by tag with fallback, caching, and circuit breaking.
  class Fetcher
    def initialize(client, limit: 10)
      @client = client
      @limit = limit
      @cache = {}
      @disabled = false
    end

    def fetch(repository_url, version)
      lookup = Lookup.new(repository_url, version)
      return nil unless fetchable?(lookup)

      cached_release(lookup)
    end

    private

    def fetchable?(lookup)
      !@disabled && lookup.valid?
    end

    def cached_release(lookup)
      key = lookup.key
      return @cache[key] if @cache.key?(key)
      return nil if @cache.size >= @limit

      @cache[key] = fetch_release(lookup)
    end

    def fetch_release(lookup)
      lookup.tags.lazy
        .filter_map { |tag| release_for(lookup.repository_name, tag) }
        .first
    rescue Octokit::Error => error
      disable_after_error(error)
    end

    def disable_after_error(error)
      puts("Release notes disabled after GitHub API error: #{error.message}")
      @disabled = true
      nil
    end

    def release_for(repo, tag)
      @client.release_for_tag(repo, tag)
    rescue Octokit::NotFound
      nil
    end
  end

  # Normalized update detail used by the release notes section.
  class Detail
    def initialize(attributes)
      @attributes = attributes
    end

    def repository_url
      value(:repository_url)
    end

    def available_version
      value(:available_version)
    end

    def package
      value(:package)
    end

    private

    def value(key)
      @attributes[key] || @attributes[key.to_s]
    end
  end
  private_constant :Detail

  # Sanitized release body suitable for PR comments.
  class Body
    LIMIT = 1_500

    def initialize(release)
      @body = release.to_h.values_at(:body, "body").compact.first.to_s
    end

    def text
      truncated_body.gsub(/@(\w)/, "@\u200B\\1")
    end

    private

    def truncated_body
      return @body if @body.length <= LIMIT

      "#{@body[0, LIMIT]}…"
    end
  end
  private_constant :Body

  # Renders one release notes details block.
  class Block
    def initialize(attributes, fetcher)
      @detail = Detail.new(attributes)
      @fetcher = fetcher
    end

    def markdown
      return if body.empty?

      <<~MARKDOWN.chomp
        <details>
        <summary>📝 Release notes: #{@detail.package} #{@detail.available_version}</summary>

        #{body}

        </details>
      MARKDOWN
    end

    private

    def body
      @body ||= Body.new(release).text
    end

    def release
      @fetcher.fetch(@detail.repository_url, @detail.available_version)
    end
  end
  private_constant :Block

  # Renders fetched release notes as collapsed Markdown details blocks.
  class Section
    def initialize(details, fetcher)
      @details = Array(details)
      @fetcher = fetcher
    end

    def markdown
      sections = @details.filter_map { |detail| Block.new(detail, @fetcher).markdown }
      sections.join("\n\n") unless sections.empty?
    end
  end
end
