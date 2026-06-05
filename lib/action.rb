#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "action_reporter"
require_relative "github_integration"
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

  def initialize
    @github_integration = GithubIntegration.new
  end

  def run
    inputs = read_inputs
    print_config(inputs)
    move_to_workspace

    checker = configure_checker(inputs)
    warnings = run_checks(checker, inputs)
    warning_details = checker.warning_details if checker.respond_to?(:warning_details)
    report(warnings, warning_details)
    fail_with("Found #{warnings.size} SPM dependency update#{warnings.size == 1 ? '' : 's'}") if inputs[:fail_on_updates] && !warnings.empty?

    puts "SPM version check completed successfully!"
  rescue ModeError => e
    fail_with(e.message)
  rescue XcodeParser::XcodeprojPathMustBeSet
    fail_with("Invalid Xcode project path")
  rescue XcodeParser::CouldNotFindResolvedFile
    fail_with("Could not find a Package.resolved file for the Xcode project")
  rescue ManifestParser::CouldNotFindManifest => e
    fail_with("Could not find Package.swift manifest: #{e.message}")
  rescue ManifestParser::CouldNotFindResolvedFile => e
    fail_with(
      "Could not find any Package.resolved file (looked in: #{e.message}). " \
      "Commit a Package.resolved next to each manifest or set package-resolved-paths."
    )
  rescue StandardError => e
    puts e.backtrace if ENV["DEBUG"]
    fail_with(e.message)
  end

  private

  def read_inputs
    {
      xcode_project_path: env_value("INPUT_XCODE_PROJECT_PATH"),
      manifest_paths: env_lines("INPUT_PACKAGE_MANIFEST_PATHS"),
      resolved_paths: env_lines("INPUT_PACKAGE_RESOLVED_PATHS"),
      check_when_exact: env_flag("INPUT_CHECK_WHEN_EXACT"),
      check_branches: env_flag("INPUT_CHECK_BRANCHES", default: true),
      check_revisions: env_flag("INPUT_CHECK_REVISIONS"),
      report_above_maximum: env_flag("INPUT_REPORT_ABOVE_MAXIMUM"),
      report_pre_releases: env_flag("INPUT_REPORT_PRE_RELEASES"),
      ignore_repos: env_csv("INPUT_IGNORE_REPOS"),
      allow_hosts: env_csv("INPUT_ALLOW_HOSTS"),
      fail_on_updates: env_flag("INPUT_FAIL_ON_UPDATES")
    }
  end

  def print_config(inputs)
    puts "SPM Version Updates GitHub Action"
    puts "Xcode project: #{inputs[:xcode_project_path]}" if inputs[:xcode_project_path]
    puts "Package manifests: #{inputs[:manifest_paths].join(', ')}" unless inputs[:manifest_paths].empty?
    puts "Package resolved: #{inputs[:resolved_paths].join(', ')}" unless inputs[:resolved_paths].empty?
    puts "Check when exact: #{inputs[:check_when_exact]}"
    puts "Check branches: #{inputs[:check_branches]}"
    puts "Check revisions: #{inputs[:check_revisions]}"
    puts "Report above maximum: #{inputs[:report_above_maximum]}"
    puts "Report pre-releases: #{inputs[:report_pre_releases]}"
    puts "Ignore repos: #{inputs[:ignore_repos].join(', ')}" unless inputs[:ignore_repos].empty?
    puts "Allow hosts: #{inputs[:allow_hosts].join(', ')}" unless inputs[:allow_hosts].empty?
    puts "Fail on updates: #{inputs[:fail_on_updates]}"
  end

  def configure_checker(inputs)
    checker = SpmChecker.new
    checker.check_when_exact = inputs[:check_when_exact]
    checker.check_branches = inputs[:check_branches]
    checker.check_revisions = inputs[:check_revisions]
    checker.report_above_maximum = inputs[:report_above_maximum]
    checker.report_pre_releases = inputs[:report_pre_releases]
    checker.ignore_repos = inputs[:ignore_repos]
    checker.allow_hosts = inputs[:allow_hosts]
    checker
  end

  def run_checks(checker, inputs)
    xcode = inputs[:xcode_project_path]
    manifests = inputs[:manifest_paths]

    if xcode && !manifests.empty?
      raise(ModeError, "Set either xcode-project-path or package-manifest-paths, not both.")
    elsif !manifests.empty?
      puts "Mode: Swift package manifests"
      checker.check_manifests(manifests, inputs[:resolved_paths])
    elsif xcode
      puts "Mode: Xcode project"
      checker.check_for_updates(xcode)
    else
      raise(ModeError, "Set either xcode-project-path or package-manifest-paths.")
    end
  end

  def report(warnings, warning_details = nil)
    ActionReporter.new(warnings, warning_details).write

    if warnings.empty?
      puts "✅ All SPM dependencies are up to date!"
      @github_integration.post_comment("✅ **SPM Dependencies**: All dependencies are up to date!")
    else
      puts "⚠️  Found #{warnings.size} potential updates"
      @github_integration.post_comment_with_warnings(warnings, warning_details)
    end
  end

  def move_to_workspace
    workspace = ENV["GITHUB_WORKSPACE"]
    return unless workspace && Dir.exist?(workspace)

    Dir.chdir(workspace)
    puts "Changed to workspace directory: #{workspace}"
  end

  def fail_with(message)
    puts "Error: #{message}"
    exit 1
  end

  def env_value(key)
    value = ENV[key]
    value.nil? || value.strip.empty? ? nil : value.strip
  end

  def env_lines(key)
    (ENV[key] || "").split("\n").map(&:strip).reject(&:empty?)
  end

  def env_csv(key)
    (ENV[key] || "").split(",").map(&:strip).reject(&:empty?)
  end

  def env_flag(key, default: false)
    value = ENV[key]
    return default if value.nil? || value.strip.empty?

    value.strip == "true"
  end
end

# Run the action
Action.new.run if __FILE__ == $PROGRAM_NAME
