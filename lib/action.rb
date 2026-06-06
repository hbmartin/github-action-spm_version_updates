# frozen_string_literal: true

require_relative "action_reporter"
require_relative "fail_on_threshold"
require_relative "github_integration"
require_relative "reporter_sink"
require_relative "spm_checker"

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
  class ModeError < StandardError; end

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
      comment_on_success: "Comment on success",
      cache_version_tags: "Cache version tags",
      version_tags_cache_ttl: "Version tags cache TTL"
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
    end

    def print_filter_inputs
      print_list(:ignore_repos)
      print_optional_value(:repo_rules_path)
      print_list(:allow_hosts)
    end

    def print_report_inputs
      puts("Fail on: #{@inputs[:fail_on] || 'none'}")
      print_value(:comment_on_success)
    end

    def print_cache_inputs
      print_value(:cache_version_tags)
      print_value(:version_tags_cache_ttl)
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
  end

  def run
    inputs = read_inputs
    ConfigPrinter.new(inputs).print
    move_to_workspace

    checker = configure_checker(inputs)
    warnings = run_checks(checker, inputs)
    warning_details = checker.warning_details
    reporter = report(warnings, warning_details, comment_on_success: inputs[:comment_on_success])
    failure_message = FailOnThreshold.failure_message(inputs[:fail_on], reporter)
    fail_with(failure_message) if failure_message

    puts("SPM version check completed successfully!")
  rescue ModeError => error
    fail_with_error(error)
  rescue XcodeParser::XcodeprojPathMustBeSet
    fail_with("Invalid Xcode project path")
  rescue XcodeParser::CouldNotFindResolvedFile
    fail_with("Could not find a Package.resolved file for the Xcode project")
  rescue ManifestParser::CouldNotFindManifest => error
    fail_with("Could not find Package.swift manifest: #{error.message}")
  rescue ManifestParser::CouldNotFindResolvedFile => error
    fail_with(
      "Could not find any Package.resolved file (looked in: #{error.message}). " \
      "Commit a Package.resolved next to each manifest or set package-resolved-paths."
    )
  rescue SpmChecker::DisallowedRepositoryHost => error
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
    raise(ArgumentError, "INPUT_VERSION_TAGS_CACHE_TTL must be an integer") unless cache_ttl

    {
      xcode_project_path: env_value("INPUT_XCODE_PROJECT_PATH"),
      manifest_paths: env_lines("INPUT_PACKAGE_MANIFEST_PATHS"),
      resolved_paths: env_lines("INPUT_PACKAGE_RESOLVED_PATHS"),
      check_when_exact: env_flag("INPUT_CHECK_WHEN_EXACT"),
      check_branches: env_flag_default_true("INPUT_CHECK_BRANCHES"),
      check_revisions: env_flag("INPUT_CHECK_REVISIONS"),
      report_above_maximum: env_flag("INPUT_REPORT_ABOVE_MAXIMUM"),
      report_pre_releases: env_flag("INPUT_REPORT_PRE_RELEASES"),
      ignore_repos: env_csv("INPUT_IGNORE_REPOS"),
      repo_rules_path: env_value("INPUT_REPO_RULES_PATH"),
      allow_hosts: env_csv("INPUT_ALLOW_HOSTS"),
      fail_on: FailOnThreshold.from_inputs(env_value("INPUT_FAIL_ON"), env_value("INPUT_FAIL_ON_UPDATES")),
      comment_on_success: env_flag("INPUT_COMMENT_ON_SUCCESS"),
      cache_version_tags: env_flag_default_true("INPUT_CACHE_VERSION_TAGS"),
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
    checker.version_tags_cache_dir = inputs[:cache_version_tags] ? inputs[:version_tags_cache_dir] : nil
    checker.version_tags_cache_ttl_seconds = inputs[:version_tags_cache_ttl]
    checker
  end

  def run_checks(checker, inputs)
    xcode = inputs[:xcode_project_path]
    manifests = inputs[:manifest_paths]
    has_manifests = !manifests.empty?

    if xcode && has_manifests
      raise(ModeError, "Set either xcode-project-path or package-manifest-paths, not both.")
    elsif has_manifests
      puts("Mode: Swift package manifests")
      checker.check_manifests(manifests, inputs[:resolved_paths])
    elsif xcode
      puts("Mode: Xcode project")
      checker.check_for_updates(xcode)
    else
      raise(ModeError, "Set either xcode-project-path or package-manifest-paths.")
    end
  end

  def report(warnings, warning_details = nil, **options)
    reporter = ActionReporter.new(warnings, warning_details)
    reporter.write

    if warnings.empty?
      puts("✅ All SPM dependencies are up to date!")
      if options.fetch(:comment_on_success, false)
        @reporter_sink.publish_success
      else
        @reporter_sink.clear
      end
    else
      puts("⚠️  Found #{warnings.size} potential updates")
      @reporter_sink.publish_updates(warnings, warning_details)
    end

    reporter
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

  def env_flag(key)
    env_value(key) == "true"
  end

  def env_flag_default_true(key)
    value = env_value(key)
    value ? value == "true" : true
  end
end

# Run the action
Action.new.run if __FILE__ == $PROGRAM_NAME
