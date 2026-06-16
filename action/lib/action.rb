# frozen_string_literal: true

require "spm_version_updates"
require_relative "action_reporter"
require_relative "github_integration"
require_relative "reporter_sink"
require_relative "timings"
require_relative "update_applier"

# Main GitHub Action entry point.
#
# Inputs are read from the environment (see `action.yml`). The action runs in
# one of two mutually exclusive source modes:
#
#   * Xcode project mode    - `xcode-project-path`
#   * Swift manifest mode    - `package-manifest-paths` (+ optional
#                              `package-resolved-paths`)
class Action
  # Raised when the configured combination of source inputs is invalid.
  class ModeError < SpmVersionUpdates::ConfigurationError; end

  # Prints the resolved action configuration in the same order as the action log.
  class ConfigPrinter
    LABELS = {
      xcode_project_path: "Xcode project",
      manifest_paths: "Package manifests",
      resolved_paths: "Package resolved",
      check_when_exact: "Check when exact",
      check_branches: "Check branches",
      check_revisions: "Check revisions",
      report_above_maximum: "Report above maximum",
      report_pre_releases: "Report pre-releases",
      ignore_repos: "Ignore repos",
      repo_rules_path: "Repo rules",
      allow_hosts: "Allow hosts",
      version_lookup_workers: "Version lookup workers",
      comment: "Comment",
      comment_on_success: "Comment on success",
      open_tracking_issue: "Open tracking issue",
      enrich_release_notes: "Enrich release notes",
      cache_version_tags: "Cache version tags",
      version_tags_cache_ttl: "Version tags cache TTL",
      allow_missing_resolved: "Allow missing resolved",
      apply_updates: "Apply updates"
    }.freeze
    private_constant :LABELS

    def initialize(inputs)
      @inputs = inputs
    end

    def print
      puts("SPM Version Updates GitHub Action")
      print_source_inputs
      print_check_inputs
      print_report_inputs
      print_cache_inputs
    end

    private

    def print_source_inputs
      print_optional_value(:xcode_project_path)
      print_list(:manifest_paths)
      print_list(:resolved_paths)
    end

    def print_check_inputs
      print_version_check_inputs
      print_filter_inputs
    end

    def print_version_check_inputs
      print_value(:check_when_exact)
      print_value(:check_branches)
      print_value(:check_revisions)
      print_value(:report_above_maximum)
      print_value(:report_pre_releases)
      print_value(:version_lookup_workers)
    end

    def print_filter_inputs
      print_list(:ignore_repos)
      print_optional_value(:repo_rules_path)
      print_list(:allow_hosts)
    end

    def print_report_inputs
      puts("Fail on: #{@inputs[:fail_on] || 'none'}")
      print_value(:comment)
      print_value(:comment_on_success)
      print_value(:open_tracking_issue)
      print_value(:enrich_release_notes)
    end

    def print_cache_inputs
      print_value(:cache_version_tags)
      print_value(:version_tags_cache_ttl)
      print_value(:allow_missing_resolved)
      print_value(:apply_updates)
    end

    def print_value(key)
      puts("#{LABELS.fetch(key)}: #{@inputs[key]}")
    end

    def print_optional_value(key)
      value = @inputs[key]
      puts("#{LABELS.fetch(key)}: #{value}") if value
    end

    def print_list(key)
      values = @inputs[key]
      puts("#{LABELS.fetch(key)}: #{values.join(', ')}") unless values.empty?
    end
  end
  private_constant :ConfigPrinter

  def initialize(reporter_sink: nil, checker_factory: SpmChecker, github_integration: nil)
    @reporter_sink = [reporter_sink, github_integration].find { |sink| sink } || GithubIntegration.new
    @checker_factory = checker_factory
    @missing_resolved = []
  end

  def run
    @timings = Timings.new
    @timings.start("Total")
    @missing_resolved = []
    inputs = read_inputs
    ConfigPrinter.new(inputs).print
    @reporter_sink.configure(inputs)
    move_to_workspace

    checker = configure_checker(inputs)
    validate_apply_mode(inputs)
    warnings = @timings.measure("Checks") { run_checks(checker, inputs) }
    warning_details = checker.warning_details
    parse_warnings = checker.parse_warnings
    applied_updates = apply_updates_if_requested(inputs, warning_details)
    @timings.finish("Total")
    reporter = report(
      warnings,
      warning_details,
      parse_warnings,
      missing_resolved: missing_resolved_records,
      applied_updates:,
      timings: @timings,
      comment: inputs[:comment],
      comment_on_success: inputs[:comment_on_success]
    )
    fail_for_apply_errors(applied_updates) if applied_updates&.failed?
    failure_message = FailOnThreshold.failure_message(inputs[:fail_on], reporter)
    fail_with(failure_message) if failure_message

    puts("SPM version check completed successfully!")
  rescue SpmVersionUpdates::ConfigurationError, SpmVersionUpdates::FileNotFoundError => error
    fail_with_error(error)
  rescue SpmVersionUpdates::ParseError => error
    fail_with("#{error.message}. Fix or regenerate this Package.resolved file.")
  rescue SpmVersionUpdates::PolicyError => error
    ActionReporter::BlockedReport.write(error.message)
    fail_with_error(error)
  rescue StandardError => error
    puts(error.backtrace) if ENV.fetch("DEBUG", nil)
    fail_with_error(error)
  end

  private

  def read_inputs
    cache_ttl_value = env_value("INPUT_VERSION_TAGS_CACHE_TTL")
    cache_ttl = Integer(cache_ttl_value || VersionTagsPersistentCache::DEFAULT_TTL_SECONDS.to_s, 10, exception: false)
    raise(SpmVersionUpdates::ConfigurationError, "INPUT_VERSION_TAGS_CACHE_TTL must be a non-negative integer") unless cache_ttl && cache_ttl >= 0

    workers = positive_integer_input("INPUT_VERSION_LOOKUP_WORKERS", SpmChecker::DEFAULT_VERSION_LOOKUP_WORKERS)

    {
      xcode_project_path: env_value("INPUT_XCODE_PROJECT_PATH"),
      manifest_paths: env_lines("INPUT_PACKAGE_MANIFEST_PATHS"),
      resolved_paths: env_lines("INPUT_PACKAGE_RESOLVED_PATHS"),
      check_when_exact: env_true?("INPUT_CHECK_WHEN_EXACT"),
      check_branches: env_true_by_default?("INPUT_CHECK_BRANCHES"),
      check_revisions: env_true?("INPUT_CHECK_REVISIONS"),
      report_above_maximum: env_true?("INPUT_REPORT_ABOVE_MAXIMUM"),
      report_pre_releases: env_true?("INPUT_REPORT_PRE_RELEASES"),
      ignore_repos: env_csv("INPUT_IGNORE_REPOS"),
      repo_rules_path: env_value("INPUT_REPO_RULES_PATH"),
      allow_hosts: env_csv("INPUT_ALLOW_HOSTS"),
      version_lookup_workers: workers,
      fail_on: FailOnThreshold.from_inputs(env_value("INPUT_FAIL_ON"), env_value("INPUT_FAIL_ON_UPDATES")),
      comment: env_true_by_default?("INPUT_COMMENT"),
      comment_on_success: env_true?("INPUT_COMMENT_ON_SUCCESS"),
      open_tracking_issue: env_true?("INPUT_OPEN_TRACKING_ISSUE"),
      allow_missing_resolved: env_true?("INPUT_ALLOW_MISSING_RESOLVED"),
      apply_updates: env_true?("INPUT_APPLY_UPDATES"),
      enrich_release_notes: env_true_by_default?("INPUT_ENRICH_RELEASE_NOTES"),
      cache_version_tags: env_true_by_default?("INPUT_CACHE_VERSION_TAGS"),
      version_tags_cache_ttl: cache_ttl,
      version_tags_cache_dir: env_value("SPM_VERSION_UPDATES_TAG_CACHE_DIR")
    }
  end

  def configure_checker(inputs)
    checker = @checker_factory.new
    repo_rules_path = inputs[:repo_rules_path]
    checker.check_when_exact = inputs[:check_when_exact]
    checker.check_branches = inputs[:check_branches]
    checker.check_revisions = inputs[:check_revisions]
    checker.report_above_maximum = inputs[:report_above_maximum]
    checker.report_pre_releases = inputs[:report_pre_releases]
    checker.ignore_repos = inputs[:ignore_repos]
    checker.repository_update_rules = RepositoryUpdateRules.load_file(repo_rules_path) if repo_rules_path
    checker.allow_hosts = inputs[:allow_hosts]
    checker.version_lookup_workers = inputs[:version_lookup_workers]
    configure_missing_resolved_handler(checker, inputs)
    checker.version_tags_cache_dir = inputs[:cache_version_tags] ? inputs[:version_tags_cache_dir] : nil
    checker.version_tags_cache_ttl_seconds = inputs[:version_tags_cache_ttl]
    checker
  end

  def run_checks(checker, inputs)
    xcode = inputs[:xcode_project_path]
    manifests = inputs[:manifest_paths]
    has_manifests = !manifests.empty?
    has_resolved = !inputs[:resolved_paths].empty?

    if xcode && has_manifests
      raise(ModeError, "Set either xcode-project-path or package-manifest-paths, not both.")
    elsif xcode && has_resolved
      raise(ModeError, "Set either xcode-project-path or package-resolved-paths, not both.")
    elsif has_manifests
      puts("Mode: Swift package manifests")
      checker.check_manifests(manifests, inputs[:resolved_paths])
    elsif xcode
      puts("Mode: Xcode project")
      checker.check_for_updates(xcode)
    elsif has_resolved
      puts("Mode: Package.resolved only")
      checker.check_resolved(inputs[:resolved_paths])
    else
      raise(ModeError, "Set xcode-project-path, package-manifest-paths, or package-resolved-paths.")
    end
  end

  def report(warnings, warning_details = nil, parse_warnings = nil, **options)
    reporter = ActionReporter.new(
      warnings,
      warning_details,
      parse_warnings,
      missing_resolved: options[:missing_resolved],
      applied_updates: options[:applied_updates],
      timings: options[:timings]
    )
    reporter.write_outputs
    reporter.emit_annotations

    if warnings.empty?
      puts("✅ All SPM dependencies are up to date!")
    else
      puts("⚠️  Found #{warnings.size} potential updates")
    end
    # The comment input only controls PR commenting; tracking-issue runs
    # (open-tracking-issue on a non-PR run) still publish their report.
    missing_resolved = options[:missing_resolved]
    publish(warnings, warning_details, parse_warnings, missing_resolved, options) if options.fetch(:comment, true) || @reporter_sink.tracking_issue_run?
    ActionReporter::TrackingIssueOutput.write(@reporter_sink.tracking_issue_result)
    reporter.write_summary

    reporter
  end

  # Parse warnings force a publish even with zero updates: a silently skipped
  # declaration must not read as "all dependencies are up to date".
  def publish(warnings, warning_details, parse_warnings, missing_resolved, options)
    if warnings.any? || Array(parse_warnings).any? || Array(missing_resolved).any?
      publish_updates(warnings, warning_details, parse_warnings, missing_resolved)
    elsif options.fetch(:comment_on_success, false)
      @reporter_sink.publish_success
    else
      @reporter_sink.clear
    end
  end

  def publish_updates(warnings, warning_details, parse_warnings, missing_resolved)
    return @reporter_sink.publish_updates(warnings, warning_details, parse_warnings, missing_resolved) unless @timings

    @timings.measure("Publish") {
      @reporter_sink.publish_updates(warnings, warning_details, parse_warnings, missing_resolved)
    }
  end

  def configure_missing_resolved_handler(checker, inputs)
    return unless inputs[:allow_missing_resolved]

    checker.missing_resolved_handler = ->(paths) { @missing_resolved.concat(paths) }
  end

  def missing_resolved_records
    @missing_resolved.map { |path|
      {
        "message" => "Package.resolved was not found; dependencies from this source may be skipped.",
        "source" => path
      }
    }
  end

  def validate_apply_mode(inputs)
    return unless inputs[:apply_updates]
    return unless inputs[:manifest_paths].empty?

    raise(SpmVersionUpdates::ConfigurationError, "apply-updates requires package-manifest-paths")
  end

  def apply_updates_if_requested(inputs, warning_details)
    return unless inputs[:apply_updates]

    @timings.measure("Apply updates") { UpdateApplier.new(warning_details).apply }
  end

  def fail_for_apply_errors(applied_updates)
    applied_updates.failed.each { |failure|
      puts(
        ActionReporter::WorkflowCommand.annotation(
          "error",
          { "title" => "SPM apply-updates failed", "file" => failure[:source] },
          failure[:error]
        )
      )
    }
    count = applied_updates.failed.size
    manifest_label = count == 1 ? "manifest" : "manifests"
    fail_with("apply-updates failed for #{count} #{manifest_label}")
  end

  def move_to_workspace
    workspace = ENV.fetch("GITHUB_WORKSPACE", nil)
    return unless workspace && Dir.exist?(workspace)

    Dir.chdir(workspace)
    puts("Changed to workspace directory: #{workspace}")
  end

  def fail_with(message)
    puts("Error: #{message}")
    exit(1)
  end

  def fail_with_error(error)
    fail_with(error.message)
  end

  def env_value(key)
    value = ENV.fetch(key, "").strip
    value.empty? ? nil : value
  end

  def env_lines(key)
    lines = ENV.fetch(key, "").split("\n")
    lines.map!(&:strip)
    lines.reject!(&:empty?)
    lines
  end

  def env_csv(key)
    values = ENV.fetch(key, "").split(",")
    values.map!(&:strip)
    values.reject!(&:empty?)
    values
  end

  def env_true?(key)
    env_value(key) == "true"
  end

  def env_true_by_default?(key)
    value = env_value(key)
    value ? value == "true" : true
  end

  def positive_integer_input(key, default)
    value = env_value(key)
    parsed = Integer(value || default.to_s, 10, exception: false)
    raise(SpmVersionUpdates::ConfigurationError, "#{key} must be a positive integer") unless parsed && parsed >= 1

    parsed
  end
end

# Run the action
Action.new.run if __FILE__ == $PROGRAM_NAME
