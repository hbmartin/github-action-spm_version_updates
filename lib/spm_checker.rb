# frozen_string_literal: true

require "semantic"
require_relative "git_operations"
require_relative "xcode_parser"

# Core SPM version checking logic (migrated from Danger plugin)
class SpmChecker
  # Whether to check when dependencies are exact versions or commits, default false
  attr_accessor :check_when_exact

  # Whether to report versions above the maximum version range, default false
  attr_accessor :report_above_maximum

  # Whether to report pre-release versions, default false
  attr_accessor :report_pre_releases

  # A list of repository URLs for packages to ignore entirely
  attr_accessor :ignore_repos

  def initialize
    @check_when_exact = false
    @report_above_maximum = false
    @report_pre_releases = false
    @ignore_repos = []
    @warnings = []
  end

  # Main method to check for SPM updates
  # @param   [String] xcodeproj_path The path to your Xcode project
  # @return  [Array<String>] Array of warning messages
  def check_for_updates(xcodeproj_path)
    @warnings.clear
    
    remote_packages = XcodeParser.get_packages(xcodeproj_path)
    resolved_versions = XcodeParser.get_resolved_versions(xcodeproj_path)
    puts "Found resolved versions for #{resolved_versions.size} packages"

    @ignore_repos = @ignore_repos&.map { |repo| GitOperations.trim_repo_url(repo) }

    remote_packages.each do |repository_url, requirement|
      next if @ignore_repos&.include?(repository_url)

      name = GitOperations.repo_name(repository_url)
      resolved_version = resolved_versions[repository_url]
      kind = requirement["kind"]

      if resolved_version.nil?
        puts "Unable to locate the current version for #{name} (#{repository_url})"
        next
      end

      if kind == "branch"
        warn_for_branch(requirement["branch"], name, repository_url, resolved_version)
        next
      end

      available_versions = GitOperations.version_tags(repository_url)
      next if available_versions.first.to_s == resolved_version

      if kind == "exactVersion" && @check_when_exact
        warn_for_new_versions_exact(available_versions, name, resolved_version)
      elsif kind == "upToNextMajorVersion"
        warn_for_new_versions(:major, available_versions, name, resolved_version)
      elsif kind == "upToNextMinorVersion"
        warn_for_new_versions(:minor, available_versions, name, resolved_version)
      elsif kind == "versionRange"
        warn_for_new_versions_range(available_versions, name, requirement, resolved_version)
      else
        puts "Not processing dependency rule '#{kind}' for #{name} (#{repository_url})"
      end
    end

    @warnings
  end

  private

  def add_warning(message)
    @warnings << message
    puts "WARNING: #{message}"
  end

  # Warns if the branch has a newer commit than the resolved version.
  # @param branch [String] the branch name
  # @param name [String] the dependency name
  # @param repository_url [String] the Git repository URL
  # @param resolved_version [String] the currently resolved version of the branch
  def warn_for_branch(branch, name, repository_url, resolved_version)
    last_commit = GitOperations.branch_last_commit(repository_url, branch)
    add_warning("Newer commit available for #{name} (#{branch}): #{last_commit}") unless last_commit == resolved_version
  end

  def warn_for_new_versions_exact(available_versions, name, resolved_version)
    newest_version = available_versions.find { |version|
      @report_pre_releases ? true : version.pre.nil?
    }
    add_warning(
      "Newer version of #{name}: #{newest_version} (but this package is set to exact version #{resolved_version})"
    ) unless newest_version.to_s == resolved_version
  end

  def warn_for_new_versions_range(available_versions, name, requirement, resolved_version)
    begin
      max_version = Semantic::Version.new(requirement["maximumVersion"])
    rescue ArgumentError => e
      puts "Unable to extract semver from #{requirement} for #{name} (#{e})"
      return
    end
    if available_versions.first < max_version
      add_warning("Newer version of #{name}: #{available_versions.first}")
    else
      newest_meeting_reqs = available_versions.find { |version|
        version < max_version && (@report_pre_releases ? true : version.pre.nil?)
      }
      add_warning("Newer version of #{name}: #{newest_meeting_reqs}") unless newest_meeting_reqs.to_s == resolved_version
      add_warning(
        "Newest version of #{name}: #{available_versions.first} (but this package is configured up to the next #{max_version} version)"
      ) if @report_above_maximum
    end
  end

  def warn_for_new_versions(major_or_minor, available_versions, name, resolved_version_string)
    begin
      resolved_version = Semantic::Version.new(resolved_version_string)
    rescue ArgumentError => e
      puts "Unable to extract semver from #{resolved_version_string} for #{name} (#{e})"
      return
    end
    newest_meeting_reqs = available_versions.find { |version|
      (version.send(major_or_minor) == resolved_version.send(major_or_minor)) && (@report_pre_releases ? true : version.pre.nil?)
    }

    add_warning("Newer version of #{name}: #{newest_meeting_reqs}") unless newest_meeting_reqs == resolved_version
    return unless @report_above_maximum

    newest_above_reqs = available_versions.find { |version|
      @report_pre_releases ? true : version.pre.nil?
    }
    add_warning(
      "Newest version of #{name}: #{available_versions.first} (but this package is configured up to the next #{major_or_minor} version)"
    ) unless newest_above_reqs == newest_meeting_reqs || newest_meeting_reqs.to_s == resolved_version
  end
end