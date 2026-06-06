# frozen_string_literal: true

require_relative "git"
require_relative "semver"
require_relative "xcode"

module Danger
  # A Danger plugin for checking if there are versions upgrades available for SPM dependencies
  #
  # @example Check if MyApp's SPM dependencies are up to date
  #          spm_version_updates.check_for_updates("MyApp.xcodeproj")
  #
  # @see  hbmartin/danger-spm_version_updates
  # @tags swift, spm, swift package manager, xcode, xcodeproj, version, updates
  #
  class DangerSpmVersionUpdates < Plugin
    # Whether to check when dependencies are exact versions or commits, default false
    # @return   [Boolean]
    attr_accessor :check_when_exact

    # Whether to report versions above the maximum version range, default false
    # @return   [Boolean]
    attr_accessor :report_above_maximum

    # Whether to report pre-release versions, default false
    # @return   [Boolean]
    attr_accessor :report_pre_releases

    # A list of repository URLs for packages to ignore entirely
    # @return   [Array<String>]
    attr_accessor :ignore_repos

    # A method that you can call from your Dangerfile
    # @param   [String] xcodeproj_path
    #          The path to your Xcode project
    # @raise [XcodeprojPathMustBeSet] if the xcodeproj_path is blank
    # @return   [void]
    def check_for_updates(xcodeproj_path)
      remote_packages = Xcode.get_packages(xcodeproj_path)
      resolved_versions = Xcode.get_resolved_versions(xcodeproj_path)
      Kernel.warn("Found resolved versions for #{resolved_versions.size} packages")
      warn_for_empty_xcode_project(remote_packages, resolved_versions, xcodeproj_path)

      self.ignore_repos = ignore_repos&.map! { |repo| Git.trim_repo_url(repo) }

      remote_packages.each { |repository_url, requirement|
        next if ignore_repos&.include?(repository_url)

        name = Git.repo_name(repository_url)
        resolved_version = resolved_versions[repository_url]
        kind = requirement["kind"]

        if resolved_version.nil?
          Kernel.warn("Unable to locate the current version for #{name} (#{repository_url})")
          next
        end

        if kind == "branch"
          warn_for_branch(requirement["branch"], name, repository_url, resolved_version)
          next
        end

        available_versions = Git.version_tags(repository_url)
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
          Kernel.warn("Not processing dependency rule '#{kind}' for #{name} (#{repository_url})")
        end
      }
    end

    private

    def warn_for_empty_xcode_project(remote_packages, resolved_versions, xcodeproj_path)
      return unless remote_packages.empty? && !resolved_versions.empty?

      Kernel.warn(
        "WARNING: No XCRemoteSwiftPackageReference entries were found in #{xcodeproj_path}, " \
        "but Package.resolved contains resolved packages. If dependencies are declared in " \
        "Package.swift files, use package-manifest-paths instead."
      )
    end

    # Warns if the branch has a newer commit than the resolved version.
    # @param branch [String] the branch name
    # @param name [String] the dependency name
    # @param repository_url [String] the Git repository URL
    # @param resolved_version [String] the currently resolved version of the branch
    def warn_for_branch(branch, name, repository_url, resolved_version)
      last_commit = Git.branch_last_commit(repository_url, branch)
      warn("Newer commit available for #{name} (#{branch}): #{last_commit}") unless last_commit == resolved_version
    end

    def warn_for_new_versions_exact(available_versions, name, resolved_version)
      newest_version = newest_reportable_version(available_versions)
      return unless newest_version
      return if newest_version.to_s == resolved_version

      warn(
        <<~TEXT
          Newer version of #{name}: #{newest_version} (but this package is set to exact version #{resolved_version})
        TEXT
      )
    end

    def warn_for_new_versions_range(available_versions, name, requirement, resolved_version)
      begin
        max_version = SpmVersionUpdates::Semver.new(requirement["maximumVersion"])
      rescue ArgumentError => error
        Kernel.warn("Unable to extract semver from #{requirement} for #{name} (#{error})")
        return
      end
      newest_version = newest_reportable_version(available_versions)
      return unless newest_version

      if newest_version < max_version
        warn("Newer version of #{name}: #{newest_version}") unless newest_version.to_s == resolved_version
      else
        newest_meeting_reqs = available_versions.find { |version|
          version < max_version && reportable_version?(version)
        }
        warn("Newer version of #{name}: #{newest_meeting_reqs}") if newest_meeting_reqs && newest_meeting_reqs.to_s != resolved_version
        if report_above_maximum
          warn(
            <<~TEXT
              Newest version of #{name}: #{newest_version} (but this package is configured up to the next #{max_version} version)
            TEXT
          )
        end
      end
    end

    def warn_for_new_versions(major_or_minor, available_versions, name, resolved_version_string)
      begin
        resolved_version = SpmVersionUpdates::Semver.new(resolved_version_string)
      rescue ArgumentError => error
        Kernel.warn("Unable to extract semver from #{resolved_version_string} for #{name} (#{error})")
        return
      end
      newest_meeting_reqs = available_versions.find { |version|
        version.major == resolved_version.major &&
          (major_or_minor == :major || version.minor == resolved_version.minor) &&
          reportable_version?(version)
      }

      warn("Newer version of #{name}: #{newest_meeting_reqs}") if newest_meeting_reqs && newest_meeting_reqs != resolved_version
      return unless report_above_maximum

      newest_above_reqs = newest_reportable_version(available_versions)
      return if newest_above_reqs == newest_meeting_reqs

      warn(
        <<~TEXT
          Newest version of #{name}: #{newest_above_reqs} (but this package is configured up to the next #{major_or_minor} version)
        TEXT
      )
    end

    def newest_reportable_version(available_versions)
      available_versions.find { |version| reportable_version?(version) }
    end

    def reportable_version?(version)
      report_pre_releases || !version.pre
    end
  end
end
