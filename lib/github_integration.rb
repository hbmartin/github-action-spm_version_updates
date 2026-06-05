# frozen_string_literal: true

require "json"
require "octokit"
require "uri"

# GitHub API integration for posting PR comments
class GithubIntegration
  COMMENT_IDENTIFIER = "<!-- spm-version-updates-action -->"

  # Parses supported git remote URLs and renders host-specific links.
  class RepositoryLink
    URL_REMOTE_PATTERN = %r{\A(?:https?|git|ssh)://(?:[^@/\s]+@)?(?<host>github\.com|gitlab\.com|bitbucket\.org)(?::\d+)?/(?<path>.+)\z}i
    SCP_REMOTE_PATTERN = %r{\A(?:[^@/\s]+@)?(?<host>github\.com|gitlab\.com|bitbucket\.org)[:/](?<path>.+)\z}i
    PATH_NORMALIZERS = {
      "github.com" => ->(segments) { segments.first(2).join("/") if segments.size >= 2 },
      "bitbucket.org" => ->(segments) { segments.first(2).join("/") if segments.size >= 2 },
      "gitlab.com" => lambda { |segments|
        project_segments = segments.take_while { |segment| segment != "-" }
        project_segments.join("/") if project_segments.size >= 2
      }
    }.freeze
    COMPARE_PATHS = {
      "github.com" => ->(current, available) { "/compare/#{current}...#{available}" },
      "gitlab.com" => ->(current, available) { "/-/compare/#{current}...#{available}" },
      "bitbucket.org" => ->(current, available) { "/branches/compare/#{available}..#{current}" }
    }.freeze
    RELEASE_LINKS = {
      "github.com" => ["Releases", "/releases"],
      "gitlab.com" => ["Releases", "/-/releases"],
      "bitbucket.org" => ["Tags", "/downloads/?tab=tags"]
    }.freeze

    def self.from(repository_url)
      link = new(repository_url)
      link if link.valid?
    end

    def initialize(repository_url)
      @value = repository_url.to_s.strip
      @host = nil
      @raw_path = nil
      @path = nil
      configure_remote(remote_match)
    end

    def valid?
      @host && @path
    end

    def compare_url(current, available)
      current_ref = URI.encode_www_form_component(current.to_s)
      available_ref = URI.encode_www_form_component(available.to_s)
      "#{base_url}#{COMPARE_PATHS.fetch(@host).call(current_ref, available_ref)}"
    end

    def release_link
      label, path = RELEASE_LINKS.fetch(@host)
      "[#{label}](#{base_url}#{path})"
    end

    def markdown_links(updates)
      compare_links = updates.map.with_index(1) { |update, index|
        label = updates.size == 1 ? "Compare" : "Compare #{index}"
        "[#{label}](#{compare_url(update[:current], update[:available])})"
      }
      (compare_links + [release_link]).join("<br>")
    end

    private

    def remote_match
      @value.match(URL_REMOTE_PATTERN) || @value.match(SCP_REMOTE_PATTERN)
    end

    def configure_remote(match)
      return unless match

      @host = match[:host].downcase
      @raw_path = match[:path]
      @path = normalized_path
    end

    def normalized_path
      PATH_NORMALIZERS.fetch(@host).call(path_segments)
    end

    def path_segments
      @raw_path.to_s
        .split(/[?#]/, 2)
        .first
        .to_s
        .sub(%r{\A/+}, "")
        .sub(%r{/+\z}, "")
        .sub(/\.git\z/i, "")
        .split("/")
        .reject(&:empty?)
    end

    def base_url
      "https://#{@host}/#{@path}"
    end
  end

  # Renders the legacy numbered warning list used when structured details are absent.
  class LegacyWarningsMessage
    def initialize(warnings, update_details)
      @warnings = warnings
      @update_details = update_details
    end

    def markdown
      <<~MARKDOWN
        #{header}#{warning_list}

        #{@update_details}
      MARKDOWN
    end

    private

    attr_reader :warnings

    def header
      "⚠️ **Found #{warning_count} potential dependency update#{warning_count > 1 ? 's' : ''}:**\n\n"
    end

    def warning_count
      @warning_count ||= warnings.size
    end

    def warning_list
      # Continuation lines (e.g. "Source: ...") are indented so they stay part
      # of the numbered list item when rendered as Markdown.
      warnings.map.with_index(1) { |warning, index|
        "#{index}. #{warning.gsub("\n", "\n   ")}"
      }.join("\n")
    end
  end

  # Renders the source column for grouped structured warning details.
  class SourceCell
    def initialize(sources, formatter)
      @sources = sources
      @formatter = formatter
    end

    def markdown
      return "Xcode project" if source_count.zero?
      return formatted_sources.first if source_count == 1

      "#{source_count} manifests<br>#{formatted_sources.join('<br>')}"
    end

    private

    attr_reader :sources, :formatter

    def source_count
      @source_count ||= sources.size
    end

    def formatted_sources
      @formatted_sources ||= sources.map { |source| formatter.call(source) }
    end
  end

  def initialize
    @github_token = ENV.fetch("GITHUB_TOKEN", nil)
    @github_repository = ENV.fetch("GITHUB_REPOSITORY", nil)
    @github_event_path = ENV.fetch("GITHUB_EVENT_PATH", nil)

    if github_token_missing?
      puts("Warning: GITHUB_TOKEN not set, comments will not be posted")
      @client = nil
      return
    end

    @client = Octokit::Client.new(access_token: @github_token)
    @pr_number = extract_pr_number

    puts("GitHub integration initialized for #{@github_repository}, PR ##{@pr_number}")
  end

  def post_comment(message)
    with_comment_target { post_comment_body(build_comment_message(message)) }
  end

  def post_comment_with_warnings(warnings, warning_details = nil)
    with_comment_target {
      message = build_warnings_message(warnings, warning_details)
      post_comment_body(build_comment_message(message))
    }
  end

  def delete_existing_comment
    with_comment_target {
      existing_comment = find_existing_comment
      delete_comment(existing_comment[:id]) if existing_comment
    }
  end

  private

  def with_comment_target
    return unless @client && @pr_number

    yield
  end

  def github_token_missing?
    @github_token.to_s.empty?
  end

  def post_comment_body(full_message)
    existing_comment = find_existing_comment
    if existing_comment
      update_comment(existing_comment[:id], full_message)
    else
      create_comment(full_message)
    end
  end

  def extract_pr_number
    return nil unless @github_event_path && File.exist?(@github_event_path)

    event_data = JSON.parse(File.read(@github_event_path))
    event_data.dig("pull_request", "number") || event_data["number"]
  rescue JSON::ParserError => error
    puts("Error parsing GitHub event data: #{error.message}")
    nil
  end

  def build_comment_message(content)
    <<~MARKDOWN
      #{COMMENT_IDENTIFIER}
      ## 📦 SPM Version Updates

      #{content}

      ---
      <sub>Generated by [SPM Version Updates Action](https://github.com/#{@github_repository})</sub>
    MARKDOWN
  end

  def build_warnings_message(warnings, warning_details = nil)
    return "✅ **All SPM dependencies are up to date!**" if warnings.empty?

    details = structured_warning_details(warning_details)
    return build_legacy_warnings_message(warnings) if details.size < warnings.size

    grouped_updates = grouped_warning_details(details)
    package_count = grouped_updates.size
    header = "⚠️ **Found #{package_count} package#{package_count == 1 ? '' : 's'} with potential dependency updates:**\n\n"
    table = grouped_updates
      .map { |group| warning_group_row(group) }
      .join("\n")

    <<~MARKDOWN
      #{header}| Package | Current → Available | Source | Links |
      | --- | --- | --- | --- |
      #{table}

      #{how_to_update_details}
    MARKDOWN
  end

  def build_legacy_warnings_message(warnings)
    LegacyWarningsMessage.new(warnings, how_to_update_details).markdown
  end

  def how_to_update_details
    <<~MARKDOWN.chomp
      <details>
      <summary>💡 How to update dependencies</summary>

      To update your SPM dependencies:
      - **Package.swift**: bump the version constraint and run `swift package update` (or `swift package resolve`)
      - **Xcode project**: go to **File → Packages → Update to Latest Package Versions**, or update individual packages from the Package Dependencies section in the Project Navigator

      </details>
    MARKDOWN
  end

  def structured_warning_details(warning_details)
    Array(warning_details).select { |detail|
      detail_value(detail, :package) &&
        detail_value(detail, :current_version) &&
        detail_value(detail, :available_version)
    }
  end

  def grouped_warning_details(details)
    details
      .group_by { |detail| detail_value(detail, :normalized_url) || detail_value(detail, :package) }
      .map { |_key, entries| warning_group(entries) }
      .sort_by { |group| group[:package].downcase }
  end

  def warning_group(entries)
    first = entries.first
    sources = entries.filter_map { |detail| detail_value(detail, :source) }
    sources.uniq!

    updates = entries.map { |detail|
      {
        current: detail_value(detail, :current_version),
        available: detail_value(detail, :available_version),
        note: detail_value(detail, :note)
      }
    }
    updates.uniq!

    {
      package: detail_value(first, :package),
      repository_url: detail_value(first, :repository_url),
      sources:,
      updates:
    }
  end

  def warning_group_row(group)
    repository = RepositoryLink.from(group[:repository_url])
    updates = group[:updates]
    links = repository ? repository.markdown_links(updates) : "N/A"

    "| #{table_cell(inline_code(group[:package]))} | #{table_cell(update_cell(updates))} | " \
      "#{table_cell(source_cell(group[:sources]))} | #{table_cell(links)} |"
  end

  def update_cell(updates)
    updates.map { |update|
      summary = "#{inline_code(display_version(update[:current]))} → #{inline_code(display_version(update[:available]))}"
      note = update[:note].to_s.strip
      note.empty? ? summary : "#{summary}<br><sub>#{table_cell(note)}</sub>"
    }.join("<br>")
  end

  def source_cell(sources)
    SourceCell.new(sources, method(:inline_code)).markdown
  end

  def detail_value(detail, key)
    detail[key] || detail[key.to_s]
  end

  def display_version(value)
    text = value.to_s
    text.match?(/\A[0-9a-f]{40}\z/i) ? text[0, 7] : text
  end

  def inline_code(value)
    text = value.to_s
    text.include?("`") ? "``#{text}``" : "`#{text}`"
  end

  def table_cell(value)
    value.to_s.gsub("|", "\\|").gsub("\n", "<br>")
  end

  def find_existing_comment
    return nil unless @pr_number

    comments = @client.issue_comments(@github_repository, @pr_number)
    comments.find { |comment| comment[:body].include?(COMMENT_IDENTIFIER) }
  rescue Octokit::Error => error
    puts("Error fetching existing comments: #{error.message}")
    nil
  end

  def create_comment(message)
    comment = @client.add_comment(@github_repository, @pr_number, message)
    puts("Created new comment: #{comment[:html_url]}")
  rescue Octokit::Error => error
    puts("Error creating comment: #{error.message}")
  end

  def update_comment(comment_id, message)
    comment = @client.update_comment(@github_repository, comment_id, message)
    puts("Updated existing comment: #{comment[:html_url]}")
  rescue Octokit::Error => error
    puts("Error updating comment: #{error.message}")
  end

  def delete_comment(comment_id)
    @client.delete_comment(@github_repository, comment_id)
    puts("Deleted resolved comment: #{comment_id}")
  rescue Octokit::Error => error
    puts("Error deleting comment: #{error.message}")
  end
end
