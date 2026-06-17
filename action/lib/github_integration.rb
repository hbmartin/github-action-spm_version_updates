# frozen_string_literal: true

require "json"
require "octokit"
require "spm_version_updates/repository_link"
require "uri"
require_relative "release_notes"
require_relative "render/markdown"
require_relative "render/missing_resolved_section"
require_relative "render/parse_warnings_section"
require_relative "report_payload"
require_relative "reporter_sink"

# GitHub-backed reporter sink for posting PR comments.
class GithubIntegration < ReporterSink
  COMMENT_IDENTIFIER = "<!-- spm-version-updates-action -->"
  TRACKING_ISSUE_RESOLVED_COMMENT = "✅ All SPM dependencies are up to date as of the latest run."

  RepositoryLink = ::RepositoryLink

  # Finds, creates, updates, and closes the single tracking issue used to
  # report updates on runs without a pull request context.
  class TrackingIssue
    # Raised when the tracking issue search reaches the configured page limit.
    class LookupExhausted < StandardError; end

    ISSUE_IDENTIFIER = "<!-- spm-version-updates-action:tracking-issue -->"
    LABEL = "spm-version-updates"
    TITLE = "Swift package dependency updates available"
    PAGE_SIZE = 100
    MAX_FIND_EXISTING_PAGES = 10

    def initialize(client, repository)
      @client = client
      @repository = repository
    end

    # Update the existing open tracking issue or create a new one.
    # @return [Hash, nil] `{ number:, url: }`, or nil when the API call failed
    def upsert(body_content)
      issue = upsert_issue(find_existing, "#{ISSUE_IDENTIFIER}\n#{body_content}")
      url = issue[:html_url]
      puts("Tracking issue: #{url}")
      { number: issue[:number], url: }
    rescue Octokit::Error, LookupExhausted => error
      puts("Error upserting tracking issue: #{error.message}")
      nil
    end

    # Close the open tracking issue, leaving a resolution comment. No-op when
    # no tracking issue exists.
    def close(comment)
      number = find_existing&.[](:number)
      return unless number

      @client.add_comment(@repository, number, comment)
      @client.close_issue(@repository, number)
      puts("Closed resolved tracking issue ##{number}")
    rescue Octokit::Error, LookupExhausted => error
      puts("Error closing tracking issue: #{error.message}")
    end

    private

    def upsert_issue(existing, body)
      return @client.update_issue(@repository, existing[:number], TITLE, body) if existing

      create_issue(body)
    end

    def create_issue(body)
      @client.create_issue(@repository, TITLE, body, labels: LABEL)
    rescue Octokit::UnprocessableEntity
      # Tokens that cannot create the label can still create the issue; the
      # body marker alone keeps find_existing working.
      @client.create_issue(@repository, TITLE, body)
    end

    # The issues API also returns pull requests, and the label can be reused by
    # humans, so both the marker and the pull_request check guard the match.
    # Label-squatting issues can push the real tracking issue past the first
    # page, so paging continues until the marker-bearing issue is found.
    def find_existing
      1.upto(MAX_FIND_EXISTING_PAGES) { |page|
        issues = open_labeled_issues(page)
        match = matching_tracking_issue(issues)
        return match if match || issues.size < PAGE_SIZE
      }

      raise(LookupExhausted, "tracking issue lookup exceeded #{MAX_FIND_EXISTING_PAGES} pages")
    end

    def open_labeled_issues(page)
      @client.list_issues(@repository, state: "open", labels: LABEL, per_page: PAGE_SIZE, page:)
    end

    def matching_tracking_issue(issues)
      issues.find { |issue| !issue[:pull_request] && issue[:body].to_s.include?(ISSUE_IDENTIFIER) }
    end
  end

  # Renders the collapsed "How to update dependencies" section. With structured
  # details it emits concrete `swift package update` commands (grouped by
  # manifest directory) and the manifest requirement changes needed for
  # out-of-range updates; otherwise it falls back to generic guidance.
  class UpgradeHintsSection
    STATIC_GUIDANCE = <<~MARKDOWN.chomp
      To update your SPM dependencies:
      - **Package.swift**: bump the version constraint and run `swift package update` (or `swift package resolve`)
      - **Xcode project**: go to **File → Packages → Update to Latest Package Versions**, or update individual packages from the Package Dependencies section in the Project Navigator
    MARKDOWN

    def initialize(details = nil)
      @details = Array(details)
    end

    def markdown
      <<~MARKDOWN.chomp
        <details>
        <summary>💡 How to update dependencies</summary>

        #{body}

        </details>
      MARKDOWN
    end

    private

    def body
      sections = [command_section, requirement_section].compact
      sections.empty? ? STATIC_GUIDANCE : sections.join("\n\n")
    end

    def value(detail, key)
      detail[key] || detail[key.to_s]
    end

    def command_section
      blocks = commands_by_directory.map { |directory, identities| command_block(directory, identities) }
      blocks.join("\n\n") unless blocks.empty?
    end

    def command_block(directory, identities)
      <<~MARKDOWN.chomp
        Run in #{directory_label(directory)}:

        ```sh
        swift package update #{identities.join(' ')}
        ```
      MARKDOWN
    end

    def directory_label(directory)
      directory == "." ? "the repository root" : "`#{directory}`"
    end

    def commands_by_directory
      @details.each_with_object({}) { |detail, grouped|
        next unless value(detail, :suggested_command)

        add_command_identity(grouped, detail)
      }
    end

    def add_command_identity(grouped, detail)
      identity = value(detail, :package_identity).to_s.strip
      return if identity.empty?

      identities = grouped[File.dirname(value(detail, :source).to_s)] ||= []
      identities << identity unless identities.include?(identity)
    end

    def requirement_section
      rows = @details.filter_map { |detail| requirement_row(detail) }
      return nil if rows.empty?

      <<~MARKDOWN.chomp
        Manifest changes needed before updating:

        | Package | New requirement | Source |
        | --- | --- | --- |
        #{rows.join("\n")}
      MARKDOWN
    end

    def requirement_row(detail)
      requirement = value(detail, :suggested_requirement)
      return unless requirement

      "| `#{value(detail, :package)}` | `#{requirement}` | `#{value(detail, :source) || 'Xcode project'}` |"
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

  # Assembles the optional sections that make up an update comment.
  class ReportSections
    def initialize(payload, updates_markdown)
      @payload = payload
      @updates_markdown = updates_markdown
    end

    def to_a
      [
        @updates_markdown,
        Render::ParseWarningsSection.new(@payload.parse_warnings).comment_markdown,
        Render::MissingResolvedSection.new(@payload.missing_resolved).comment_markdown,
      ]
    end
  end
  private_constant :ReportSections

  # The issue created or updated by the last publish (see ReporterSink).
  attr_reader :tracking_issue_result

  def initialize
    super
    @github_token = ENV.fetch("GITHUB_TOKEN", nil)
    @github_repository = ENV.fetch("GITHUB_REPOSITORY", nil)
    @github_event_path = ENV.fetch("GITHUB_EVENT_PATH", nil)
    @open_tracking_issue = false
    @enrich_release_notes = true
    @tracking_issue_result = nil

    if github_token_missing?
      puts("Warning: GITHUB_TOKEN not set, comments will not be posted")
      @client = nil
      return
    end

    @client = Octokit::Client.new(access_token: @github_token)
    @pr_number = extract_pr_number

    puts("GitHub integration initialized for #{@github_repository}, PR ##{@pr_number}")
  end

  def configure(inputs)
    @open_tracking_issue = inputs.fetch(:open_tracking_issue, false)
    @enrich_release_notes = inputs.fetch(:enrich_release_notes, true)
  end

  # Tracking-issue mode applies only on runs without a pull request context
  # (schedule, workflow_dispatch, push) when explicitly enabled. Public so the
  # action can publish tracking issues even when PR commenting is disabled.
  def tracking_issue_run?
    !!(@open_tracking_issue && !@pr_number && @client && @github_repository)
  end

  def publish_updates(payload)
    return unless tracking_issue_run? || comment_target?

    message = build_comment_message(build_warnings_message(payload))
    if tracking_issue_run?
      @tracking_issue_result = tracking_issue.upsert(message)
    else
      post_comment_body(message)
    end
  end

  def publish_success
    return tracking_issue.close(TRACKING_ISSUE_RESOLVED_COMMENT) if tracking_issue_run?

    post_comment(SUCCESS_MESSAGE)
  end

  def clear
    return tracking_issue.close(TRACKING_ISSUE_RESOLVED_COMMENT) if tracking_issue_run?

    with_comment_target {
      existing_comment = find_existing_comment
      delete_comment(existing_comment[:id]) if existing_comment
    }
  end

  def post_comment(message)
    with_comment_target { post_comment_body(build_comment_message(message)) }
  end

  def delete_existing_comment
    clear
  end

  private

  def tracking_issue
    @tracking_issue ||= TrackingIssue.new(@client, @github_repository)
  end

  def comment_target?
    @client && @pr_number
  end

  def with_comment_target
    return unless comment_target?

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

  def build_warnings_message(payload)
    ReportSections.new(payload, updates_message(payload)).to_a.compact.join("\n\n")
  end

  def updates_message(payload)
    updates = payload.updates
    return "✅ **All SPM dependencies are up to date!**" if updates.empty?

    grouped_updates = grouped_update_records(updates)
    package_count = grouped_updates.size
    package_label = package_count == 1 ? "package" : "packages"
    header = "⚠️ **Found #{package_count} #{package_label} with potential dependency updates:**\n\n"
    table = grouped_updates
      .map { |group| warning_group_row(group) }
      .join("\n")

    [
      "#{header}| Package | Current → Available | Source | Links |\n| --- | --- | --- | --- |\n#{table}",
      UpgradeHintsSection.new(updates).markdown,
      release_notes_markdown(updates),
    ]
      .compact
      .join("\n\n")
  end

  def grouped_update_records(details)
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
      repository_url: first_present_repository_url(entries),
      sources:,
      updates:
    }
  end

  def first_present_repository_url(entries)
    first_present_detail_value(entries, :repository_url) || first_present_detail_value(entries, :normalized_url)
  end

  def first_present_detail_value(entries, key)
    entries
      .filter_map { |detail| present_detail_value(detail, key) }
      .first
  end

  def present_detail_value(detail, key)
    value = detail_value(detail, key).to_s.strip
    value unless value.empty?
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
    Render::Markdown.display_version(value)
  end

  def inline_code(value)
    Render::Markdown.inline_code(value)
  end

  def table_cell(value)
    Render::Markdown.table_cell(value)
  end

  def release_notes_markdown(details)
    return unless @client && @enrich_release_notes

    ReleaseNotes::Section.new(details, release_notes_fetcher).markdown
  end

  def release_notes_fetcher
    @release_notes_fetcher ||= ReleaseNotes::Fetcher.new(@client)
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
