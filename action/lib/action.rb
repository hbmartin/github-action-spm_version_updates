# frozen_string_literal: true

require "spm_version_updates"
require_relative "action_reporter"
require_relative "github_integration"
require_relative "report_payload"
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
    VERSION_CHECK_KEYS = %i(
      check_when_exact
      check_branches
      check_revisions
      report_above_maximum
      report_pre_releases
      version_lookup_workers
    ).freeze
    private_constant :LABELS
    private_constant :VERSION_CHECK_KEYS

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
      VERSION_CHECK_KEYS.each { |key| print_value(key) }
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

  # Reads and normalizes GitHub Action inputs from the environment.
  class Inputs
    DEFAULT_TRUE_VALUES = { nil => true, "true" => true }.freeze
    private_constant :DEFAULT_TRUE_VALUES

    def initialize(env = ENV)
      @env = env
    end

    def to_h
      source_inputs
        .merge(check_inputs)
        .merge(report_inputs)
        .merge(cache_inputs)
    end

    private

    attr_reader :env

    def source_inputs
      {
        xcode_project_path: env_value("INPUT_XCODE_PROJECT_PATH"),
        manifest_paths: env_lines("INPUT_PACKAGE_MANIFEST_PATHS"),
        resolved_paths: env_lines("INPUT_PACKAGE_RESOLVED_PATHS")
      }
    end

    def check_inputs
      {
        check_when_exact: env_true?("INPUT_CHECK_WHEN_EXACT"),
        check_branches: env_true_by_default?("INPUT_CHECK_BRANCHES"),
        check_revisions: env_true?("INPUT_CHECK_REVISIONS"),
        report_above_maximum: env_true?("INPUT_REPORT_ABOVE_MAXIMUM"),
        report_pre_releases: env_true?("INPUT_REPORT_PRE_RELEASES"),
        ignore_repos: env_csv("INPUT_IGNORE_REPOS"),
        repo_rules_path: env_value("INPUT_REPO_RULES_PATH"),
        allow_hosts: env_csv("INPUT_ALLOW_HOSTS"),
        version_lookup_workers: positive_integer_input("INPUT_VERSION_LOOKUP_WORKERS", SpmChecker::DEFAULT_VERSION_LOOKUP_WORKERS)
      }
    end

    def report_inputs
      {
        fail_on: FailOnThreshold.from_input(env_value("INPUT_FAIL_ON")),
        comment: env_true_by_default?("INPUT_COMMENT"),
        comment_on_success: env_true?("INPUT_COMMENT_ON_SUCCESS"),
        open_tracking_issue: env_true?("INPUT_OPEN_TRACKING_ISSUE"),
        allow_missing_resolved: env_true?("INPUT_ALLOW_MISSING_RESOLVED"),
        apply_updates: env_true?("INPUT_APPLY_UPDATES"),
        enrich_release_notes: env_true_by_default?("INPUT_ENRICH_RELEASE_NOTES")
      }
    end

    def cache_inputs
      {
        cache_version_tags: env_true_by_default?("INPUT_CACHE_VERSION_TAGS"),
        version_tags_cache_ttl: version_tags_cache_ttl,
        version_tags_cache_dir: env_value("SPM_VERSION_UPDATES_TAG_CACHE_DIR")
      }
    end

    def version_tags_cache_ttl
      value = env_value("INPUT_VERSION_TAGS_CACHE_TTL")
      parsed = Integer(value || VersionTagsPersistentCache::DEFAULT_TTL_SECONDS.to_s, 10, exception: false)
      raise(SpmVersionUpdates::ConfigurationError, "INPUT_VERSION_TAGS_CACHE_TTL must be a non-negative integer") unless parsed && parsed >= 0

      parsed
    end

    def env_value(key)
      value = env.fetch(key, "").strip
      value.empty? ? nil : value
    end

    def env_lines(key)
      values_for(key, "\n")
    end

    def env_csv(key)
      values_for(key, ",")
    end

    def values_for(key, separator)
      env.fetch(key, "").split(separator).map(&:strip).reject(&:empty?)
    end

    def env_true?(key)
      env_value(key) == "true"
    end

    def env_true_by_default?(key)
      DEFAULT_TRUE_VALUES.fetch(env_value(key), false)
    end

    def positive_integer_input(key, default)
      value = env_value(key)
      parsed = Integer(value || default.to_s, 10, exception: false)
      raise(SpmVersionUpdates::ConfigurationError, "#{key} must be a positive integer") unless parsed && parsed >= 1

      parsed
    end
  end
  private_constant :Inputs

  # Validates whether automatic manifest updates can run for the selected mode.
  class ApplyModeValidator
    def initialize(inputs)
      @inputs = inputs
    end

    def validate
      return unless apply_updates?
      return if manifest_mode?

      raise(SpmVersionUpdates::ConfigurationError, "apply-updates requires package-manifest-paths")
    end

    private

    attr_reader :inputs

    def apply_updates?
      inputs[:apply_updates]
    end

    def manifest_mode?
      inputs[:manifest_paths].any?
    end
  end
  private_constant :ApplyModeValidator

  # Emits annotations and summary text for failed apply-updates rewrites.
  class ApplyErrorReporter
    # One failed manifest rewrite, rendered as a workflow annotation.
    class Failure
      def initialize(attributes)
        @attributes = attributes
      end

      def annotation
        ActionReporter::WorkflowCommand.annotation(
          "error",
          { "title" => "SPM apply-updates failed", "file" => @attributes[:source] },
          @attributes[:error]
        )
      end
    end
    private_constant :Failure

    def initialize(applied_updates)
      @failures = applied_updates.failed
    end

    def annotations
      @failures.map { |failure| Failure.new(failure).annotation }
    end

    def message
      "apply-updates failed for #{manifest_count_message}"
    end

    private

    def manifest_count_message
      count = @failures.size
      manifest_label = count == 1 ? "manifest" : "manifests"
      "#{count} #{manifest_label}"
    end
  end
  private_constant :ApplyErrorReporter

  # Publishes update reports with optional timing instrumentation.
  class PublishStep
    def initialize(timings, reporter_sink, payload)
      @timings = timings
      @reporter_sink = reporter_sink
      @payload = payload
    end

    def call
      return publish unless @timings

      @timings.measure("Publish") { publish }
    end

    private

    def publish
      @reporter_sink.publish_updates(@payload)
    end
  end
  private_constant :PublishStep

  def initialize(reporter_sink: nil, checker_factory: SpmChecker)
    @reporter_sink = reporter_sink || GithubIntegration.new
    @checker_factory = checker_factory
    @missing_resolved = []
    @timings = nil
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
    ApplyModeValidator.new(inputs).validate
    result = @timings.measure("Checks") { run_checks(checker, inputs) }
    applied_updates = apply_updates_if_requested(inputs, result.updates)
    @timings.finish("Total")
    reporter = report(
      report_payload(result, applied_updates),
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
    fail_with_parse_error(error)
  rescue SpmVersionUpdates::PolicyError => error
    fail_with_policy_error(error)
  rescue StandardError => error
    fail_with_unexpected_error(error)
  end

  private

  def read_inputs
    Inputs.new.to_h
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

  def report(payload, **options)
    reporter = ActionReporter.new(payload)
    reporter.write_outputs
    reporter.emit_annotations

    updates = payload.updates
    if updates.empty?
      puts("✅ All SPM dependencies are up to date!")
    else
      puts("⚠️  Found #{updates.size} potential updates")
    end
    # The comment input only controls PR commenting; tracking-issue runs
    # (open-tracking-issue on a non-PR run) still publish their report.
    publish(payload, options) if options.fetch(:comment, true) || @reporter_sink.tracking_issue_run?
    ActionReporter::TrackingIssueOutput.write(@reporter_sink.tracking_issue_result)
    reporter.write_summary

    reporter
  end

  def report_payload(result, applied_updates)
    ReportPayload.new(
      updates: result.updates,
      parse_warnings: result.parse_warnings,
      missing_resolved: missing_resolved_records,
      applied_updates:,
      timings: @timings
    )
  end

  # Parse warnings force a publish even with zero updates: a silently skipped
  # declaration must not read as "all dependencies are up to date".
  def publish(payload, options)
    if payload.updates.any? || payload.parse_warnings.any? || payload.missing_resolved.any?
      publish_updates(payload)
    elsif options.fetch(:comment_on_success, false)
      @reporter_sink.publish_success
    else
      @reporter_sink.clear
    end
  end

  def publish_updates(payload)
    PublishStep.new(@timings, @reporter_sink, payload).call
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

  def apply_updates_if_requested(inputs, updates)
    return unless inputs[:apply_updates]

    @timings.measure("Apply updates") { UpdateApplier.new(updates).apply }
  end

  def fail_for_apply_errors(applied_updates)
    reporter = ApplyErrorReporter.new(applied_updates)
    reporter.annotations.each { |annotation| puts(annotation) }
    fail_with(reporter.message)
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

  def fail_with_parse_error(error)
    fail_with("#{error.message}. Fix or regenerate this Package.resolved file.")
  end

  def fail_with_policy_error(error)
    ActionReporter::BlockedReport.write(error.to_s)
    fail_with_error(error)
  end

  def fail_with_unexpected_error(error)
    puts(error.backtrace) if ENV.fetch("DEBUG", nil)
    fail_with_error(error)
  end
end

# Run the action
Action.new.run if __FILE__ == $PROGRAM_NAME
