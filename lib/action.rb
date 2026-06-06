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

  def initialize(reporter_sink: nil, checker_factory: SpmChecker, github_integration: nil)
    @reporter_sink = [reporter_sink, github_integration].find { |sink| sink } || GithubIntegration.new
    @checker_factory = checker_factory
  end

  def run
    inputs = read_inputs
    print_config(inputs)
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
    cache_ttl = Integer(cache_ttl_value || VersionTagsPersistentCache::DEFAULT_TTL_SECONDS.to_s, exception: false)
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
      allow_hosts: env_csv("INPUT_ALLOW_HOSTS"),
      fail_on: FailOnThreshold.from_inputs(env_value("INPUT_FAIL_ON"), env_value("INPUT_FAIL_ON_UPDATES")),
      comment_on_success: env_flag("INPUT_COMMENT_ON_SUCCESS"),
      cache_version_tags: env_flag_default_true("INPUT_CACHE_VERSION_TAGS"),
      version_tags_cache_ttl: cache_ttl,
      version_tags_cache_dir: env_value("SPM_VERSION_UPDATES_TAG_CACHE_DIR")
    }
  end

  def print_config(inputs)
    xcode_project_path = inputs[:xcode_project_path]
    manifest_paths = inputs[:manifest_paths]
    resolved_paths = inputs[:resolved_paths]
    ignore_repos = inputs[:ignore_repos]
    allow_hosts = inputs[:allow_hosts]

    puts("SPM Version Updates GitHub Action")
    puts("Xcode project: #{xcode_project_path}") if xcode_project_path
    puts("Package manifests: #{manifest_paths.join(', ')}") unless manifest_paths.empty?
    puts("Package resolved: #{resolved_paths.join(', ')}") unless resolved_paths.empty?
    puts("Check when exact: #{inputs[:check_when_exact]}")
    puts("Check branches: #{inputs[:check_branches]}")
    puts("Check revisions: #{inputs[:check_revisions]}")
    puts("Report above maximum: #{inputs[:report_above_maximum]}")
    puts("Report pre-releases: #{inputs[:report_pre_releases]}")
    puts("Ignore repos: #{ignore_repos.join(', ')}") unless ignore_repos.empty?
    puts("Allow hosts: #{allow_hosts.join(', ')}") unless allow_hosts.empty?
    puts("Fail on: #{inputs[:fail_on] || 'none'}")
    puts("Comment on success: #{inputs[:comment_on_success]}")
    puts("Cache version tags: #{inputs[:cache_version_tags]}")
    puts("Version tags cache TTL: #{inputs[:version_tags_cache_ttl]}")
  end

  def configure_checker(inputs)
    checker = @checker_factory.new
    checker.check_when_exact = inputs[:check_when_exact]
    checker.check_branches = inputs[:check_branches]
    checker.check_revisions = inputs[:check_revisions]
    checker.report_above_maximum = inputs[:report_above_maximum]
    checker.report_pre_releases = inputs[:report_pre_releases]
    checker.ignore_repos = inputs[:ignore_repos]
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
