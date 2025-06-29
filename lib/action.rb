#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "spm_checker"
require_relative "github_integration"

# Main GitHub Action entry point
class Action
  def initialize
    @github_integration = GithubIntegration.new
  end

  def run
    # Parse command line arguments (passed from action.yml)
    xcodeproj_path = ARGV[0]
    check_when_exact = ARGV[1] == "true"
    report_above_maximum = ARGV[2] == "true"
    report_pre_releases = ARGV[3] == "true"
    ignore_repos = ARGV[4]&.split(",")&.map(&:strip) || []

    puts "SPM Version Updates GitHub Action"
    puts "Xcode project: #{xcodeproj_path}"
    puts "Check when exact: #{check_when_exact}"
    puts "Report above maximum: #{report_above_maximum}"
    puts "Report pre-releases: #{report_pre_releases}"
    puts "Ignore repos: #{ignore_repos.join(', ')}" unless ignore_repos.empty?

    # Validate inputs
    if xcodeproj_path.nil? || xcodeproj_path.empty?
      puts "Error: xcode-project-path is required"
      exit 1
    end

    # Change to workspace directory if available
    workspace = ENV["GITHUB_WORKSPACE"]
    if workspace && Dir.exist?(workspace)
      Dir.chdir(workspace)
      puts "Changed to workspace directory: #{workspace}"
    end

    # Configure SPM checker
    checker = SpmChecker.new
    checker.check_when_exact = check_when_exact
    checker.report_above_maximum = report_above_maximum
    checker.report_pre_releases = report_pre_releases
    checker.ignore_repos = ignore_repos

    begin
      # Run the SPM version check
      warnings = checker.check_for_updates(xcodeproj_path)
      
      if warnings.empty?
        puts "✅ All SPM dependencies are up to date!"
        @github_integration.post_comment("✅ **SPM Dependencies**: All dependencies are up to date!")
      else
        puts "⚠️  Found #{warnings.size} potential updates"
        @github_integration.post_comment_with_warnings(warnings)
      end

    rescue XcodeParser::XcodeprojPathMustBeSet
      puts "Error: Invalid Xcode project path: #{xcodeproj_path}"
      exit 1
    rescue XcodeParser::CouldNotFindResolvedFile
      puts "Error: Could not find Package.resolved file for project: #{xcodeproj_path}"
      exit 1
    rescue StandardError => e
      puts "Error: #{e.message}"
      puts e.backtrace if ENV["DEBUG"]
      exit 1
    end

    puts "SPM version check completed successfully!"
  end
end

# Run the action
if __FILE__ == $0
  Action.new.run
end