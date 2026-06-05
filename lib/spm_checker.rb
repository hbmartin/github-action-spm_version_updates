# frozen_string_literal: true

require "semantic"
require_relative "git_operations"
require_relative "xcode_parser"
require_relative "manifest_parser"
require_relative "package_resolved"

# Core SPM version checking logic (migrated from Danger plugin)
class SpmChecker
  # Whether to check when dependencies are exact versions or commits, default false
  attr_accessor :check_when_exact

  # Whether to check for newer commits on branch-pinned dependencies, default true
  attr_accessor :check_branches

  # Whether to report the latest tagged version for revision-pinned dependencies, default false
  attr_accessor :check_revisions

  # Whether to report versions above the maximum version range, default false
  attr_accessor :report_above_maximum

  # Whether to report pre-release versions, default false
  attr_accessor :report_pre_releases

  # A list of repository URLs for packages to ignore entirely
  attr_accessor :ignore_repos

  def initialize
    @check_when_exact = false
    @check_branches = true
    @check_revisions = false
    @report_above_maximum = false
    @report_pre_releases = false
    @ignore_repos = []
    @warnings = []
  end

  # Check for SPM updates using an Xcode project as the source of dependencies.
  #
  # @param   [String] xcodeproj_path The path to your Xcode project
  # @return  [Array<String>] Array of warning messages
  def check_for_updates(xcodeproj_path)
    @warnings.clear
    normalize_ignore_repos

    remote_packages = XcodeParser.get_packages(xcodeproj_path)
    resolved_versions = XcodeParser.get_resolved_versions(xcodeproj_path)
    puts "Found resolved versions for #{resolved_versions.size} packages"

    check_packages(remote_packages, resolved_versions)
    @warnings
  end

  # Check for SPM updates using one or more `Package.swift` manifests as the
  # source of dependencies.
  #
  # Resolved pins from every `Package.resolved` are merged by normalized
  # repository URL into a single lookup. Each manifest's direct dependencies are
  # then compared against that lookup, and the originating manifest is attached
  # to every warning so multi-manifest repos can tell where an update applies.
  #
  # @param   [Array<String>] manifest_paths Paths to one or more `Package.swift`
  # @param   [Array<String>, nil] resolved_paths Optional explicit
  #          `Package.resolved` paths. When omitted, a `Package.resolved` next to
  #          each manifest is used.
  # @raise [ManifestParser::CouldNotFindResolvedFile] if no resolved file exists
  # @return  [Array<String>] Array of warning messages
  def check_manifests(manifest_paths, resolved_paths = nil)
    @warnings.clear
    normalize_ignore_repos

    resolved_versions = merged_resolved_versions(manifest_paths, resolved_paths)
    puts "Found resolved versions for #{resolved_versions.size} packages"

    manifest_paths.each { |manifest_path|
      remote_packages = ManifestParser.get_packages(manifest_path)
      check_packages(remote_packages, resolved_versions, manifest_path)
    }
    @warnings
  end

  private

  def normalize_ignore_repos
    @ignore_repos = @ignore_repos&.map { |repo| GitOperations.trim_repo_url(repo) }
  end

  # Merge the resolved pins of every relevant `Package.resolved` file.
  #
  # Every expected resolved file must exist. A missing one would silently drop a
  # manifest's pins and produce misleading "all up to date" results, so we fail
  # loudly and name the missing file(s) instead.
  #
  # @return [Hash<String, String>]
  def merged_resolved_versions(manifest_paths, resolved_paths)
    paths = Array(resolved_paths).reject { |path| path.nil? || path.empty? }
    paths = manifest_paths.map { |manifest| ManifestParser.default_resolved_path(manifest) } if paths.empty?

    missing = paths.reject { |path| File.exist?(path) }
    raise(ManifestParser::CouldNotFindResolvedFile, missing.join(", ")) unless missing.empty?

    puts "Reading resolved packages from: #{paths}"
    paths.each_with_object({}) { |path, pins| pins.merge!(PackageResolved.versions_from(path)) }
  end

  # Compare a set of declared dependencies against the resolved pins.
  #
  # Packages are keyed by their normalized repository URL, which is what we match
  # against `resolved_versions` and `ignore_repos`. The original, scheme-bearing
  # URL travels in the entry as `repository_url` and is what we hand to git --
  # the normalized key is not a valid git remote.
  #
  # @param remote_packages [Hash<String, Hash>] normalized URL => { "repository_url", "requirement" }
  # @param resolved_versions [Hash<String, String>] normalized URL => version
  # @param source [String, nil] the manifest a warning should be attributed to
  def check_packages(remote_packages, resolved_versions, source = nil)
    remote_packages.each { |normalized_url, entry|
      next if @ignore_repos&.include?(normalized_url)

      repository_url = entry["repository_url"]
      requirement = entry["requirement"]
      next if requirement.nil?

      name = GitOperations.repo_name(normalized_url)
      resolved_version = resolved_versions[normalized_url]
      kind = requirement["kind"]

      if resolved_version.nil?
        puts "Unable to locate the current version for #{name} (#{repository_url})"
        next
      end

      if kind == "branch"
        warn_for_branch(requirement["branch"], name, repository_url, resolved_version, source) if @check_branches
        next
      end

      if kind == "revision"
        warn_for_revision(name, repository_url, resolved_version, source) if @check_revisions
        next
      end

      check_versioned_package(kind, name, repository_url, requirement, resolved_version, source)
    }
  end

  def check_versioned_package(kind, name, repository_url, requirement, resolved_version, source)
    return if kind == "exactVersion" && !@check_when_exact

    available_versions = GitOperations.version_tags(repository_url)
    return if available_versions.empty?
    return if available_versions.first.to_s == resolved_version

    if kind == "exactVersion"
      warn_for_new_versions_exact(available_versions, name, resolved_version, source)
    elsif kind == "upToNextMajorVersion"
      warn_for_new_versions(:major, available_versions, name, resolved_version, source)
    elsif kind == "upToNextMinorVersion"
      warn_for_new_versions(:minor, available_versions, name, resolved_version, source)
    elsif kind == "versionRange"
      warn_for_new_versions_range(available_versions, name, requirement, resolved_version, source)
    else
      puts "Not processing dependency rule '#{kind}' for #{name} (#{repository_url})"
    end
  end

  def add_warning(message, source = nil)
    full_message = source.nil? ? message : "#{message}\nSource: #{source}"
    @warnings << full_message
    puts "WARNING: #{message}#{source ? " (#{source})" : ''}"
  end

  # Warns if the branch has a newer commit than the resolved version.
  # @param branch [String] the branch name
  # @param name [String] the dependency name
  # @param repository_url [String] the Git repository URL
  # @param resolved_version [String] the currently resolved version of the branch
  # @param source [String, nil] the originating manifest, when applicable
  def warn_for_branch(branch, name, repository_url, resolved_version, source = nil)
    last_commit = GitOperations.branch_last_commit(repository_url, branch)
    return if last_commit.nil?

    add_warning("Newer commit available for #{name} (#{branch}): #{last_commit}", source) unless last_commit == resolved_version
  end

  # Reports the latest tagged version for a dependency pinned to a raw revision.
  # There is no general way to know whether an arbitrary commit is behind, so
  # this is purely informational and only runs when +check_revisions+ is enabled.
  def warn_for_revision(name, repository_url, resolved_version, source = nil)
    available_versions = GitOperations.version_tags(repository_url)
    newest_version = available_versions.find { |version| @report_pre_releases ? true : version.pre.nil? }
    return if newest_version.nil?

    add_warning(
      "#{name} is pinned to a revision (#{resolved_version}); latest tagged version is #{newest_version}",
      source
    )
  end

  def warn_for_new_versions_exact(available_versions, name, resolved_version, source = nil)
    newest_version = available_versions.find { |version|
      @report_pre_releases ? true : version.pre.nil?
    }
    return if newest_version.nil?

    add_warning(
      "Newer version of #{name}: #{newest_version} (but this package is set to exact version #{resolved_version})",
      source
    ) unless newest_version.to_s == resolved_version
  end

  def warn_for_new_versions_range(available_versions, name, requirement, resolved_version, source = nil)
    begin
      max_version = Semantic::Version.new(requirement["maximumVersion"])
    rescue ArgumentError => e
      puts "Unable to extract semver from #{requirement} for #{name} (#{e})"
      return
    end
    # Honor the pre-release policy: never report a pre-release as the newest
    # version when report_pre_releases is false.
    newest = available_versions.find { |version| @report_pre_releases ? true : version.pre.nil? }
    return if newest.nil?

    if newest < max_version
      add_warning("Newer version of #{name}: #{newest}", source) unless newest.to_s == resolved_version
    else
      newest_meeting_reqs = available_versions.find { |version|
        version < max_version && (@report_pre_releases ? true : version.pre.nil?)
      }
      add_warning("Newer version of #{name}: #{newest_meeting_reqs}", source) unless newest_meeting_reqs.nil? || newest_meeting_reqs.to_s == resolved_version
      add_warning(
        "Newest version of #{name}: #{newest} (but this package is configured up to the next #{max_version} version)",
        source
      ) if @report_above_maximum
    end
  end

  def warn_for_new_versions(major_or_minor, available_versions, name, resolved_version_string, source = nil)
    begin
      resolved_version = Semantic::Version.new(resolved_version_string)
    rescue ArgumentError => e
      puts "Unable to extract semver from #{resolved_version_string} for #{name} (#{e})"
      return
    end
    # upToNextMajor allows any version with the same major; upToNextMinor additionally
    # requires the same minor. Comparing minor alone would wrongly match e.g. 2.5.0
    # against a resolved 1.5.0.
    newest_meeting_reqs = available_versions.find { |version|
      version.major == resolved_version.major &&
        (major_or_minor == :major || version.minor == resolved_version.minor) &&
        (@report_pre_releases ? true : version.pre.nil?)
    }

    add_warning("Newer version of #{name}: #{newest_meeting_reqs}", source) unless newest_meeting_reqs.nil? || newest_meeting_reqs == resolved_version
    return unless @report_above_maximum

    newest_above_reqs = available_versions.find { |version|
      @report_pre_releases ? true : version.pre.nil?
    }
    # Suppressed only when nothing exists above the constraint (the newest overall
    # is the newest in-constraint version). Being at the newest in-constraint
    # version is intentionally still reported here, since report_above_maximum
    # exists precisely to surface the out-of-range (e.g. next major) version.
    add_warning(
      "Newest version of #{name}: #{newest_above_reqs} (but this package is configured up to the next #{major_or_minor} version)",
      source
    ) unless newest_above_reqs == newest_meeting_reqs
  end
end
