# frozen_string_literal: true

require "semantic"
require_relative "git_operations"
require_relative "manifest_parser"
require_relative "package_resolved"
require_relative "xcode_parser"

# Core SPM version checking logic (migrated from Danger plugin)
class SpmChecker
  VERSION_TAG_WORKER_COUNT = 8

  class DisallowedRepositoryHost < StandardError; end

  # Structured facts about each warning, used by the GitHub Action comment
  # renderer. `check_for_updates` and `check_manifests` still return the legacy
  # string warnings for compatibility with existing plugin-style callers.
  attr_reader :warning_details

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

  # A list of git remote hostnames allowed for dependency version lookups
  attr_accessor :allow_hosts

  def initialize
    @check_when_exact = false
    @check_branches = true
    @check_revisions = false
    @report_above_maximum = false
    @report_pre_releases = false
    @ignore_repos = []
    @allow_hosts = []
    @warnings = []
    @warning_details = []
    @version_tags_cache = {}
  end

  # Check for SPM updates using an Xcode project as the source of dependencies.
  #
  # @param   [String] xcodeproj_path The path to your Xcode project
  # @return  [Array<String>] Array of warning messages
  def check_for_updates(xcodeproj_path)
    clear_warnings
    reset_version_tags_cache
    normalize_ignore_repos
    normalize_allow_hosts

    remote_packages = XcodeParser.get_packages(xcodeproj_path)
    resolved_versions = XcodeParser.get_resolved_versions(xcodeproj_path)
    puts("Found resolved versions for #{resolved_versions.size} packages")

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
    clear_warnings
    reset_version_tags_cache
    normalize_ignore_repos
    normalize_allow_hosts

    resolved_versions = merged_resolved_versions(manifest_paths, resolved_paths)
    puts("Found resolved versions for #{resolved_versions.size} packages")

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

  def normalize_allow_hosts
    @allow_hosts = Array(@allow_hosts)
      .filter_map { |host| GitOperations.host(host) || host.to_s.strip.downcase }
      .reject(&:empty?)
  end

  def clear_warnings
    @warnings.clear
    @warning_details.clear
  end

  def reset_version_tags_cache
    @version_tags_cache = {}
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

    puts("Reading resolved packages from: #{paths}")
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
    packages = package_contexts(remote_packages, resolved_versions, source)
    prefetch_version_tags(packages)

    packages.each { |package|
      if package[:kind] == "branch"
        warn_for_branch(
          package[:requirement]["branch"],
          package[:name],
          package[:normalized_url],
          package[:repository_url],
          package[:resolved_version],
          package[:source]
        ) if @check_branches
        next
      end

      if package[:kind] == "revision"
        warn_for_revision(
          package[:name],
          package[:normalized_url],
          package[:repository_url],
          package[:resolved_version],
          version_tags_for(package),
          package[:source]
        ) if @check_revisions
        next
      end

      check_versioned_package(
        package[:kind],
        package[:name],
        package[:normalized_url],
        package[:repository_url],
        package[:requirement],
        package[:resolved_version],
        package[:source],
        version_tags_for(package)
      )
    }
  end

  def package_contexts(remote_packages, resolved_versions, source)
    remote_packages.filter_map { |normalized_url, entry|
      next if @ignore_repos&.include?(normalized_url)

      repository_url = entry["repository_url"]
      requirement = entry["requirement"]
      next if requirement.nil?

      name = GitOperations.repo_name(normalized_url)
      ensure_repository_host_allowed!(name, repository_url, source)

      resolved_version = resolved_versions[normalized_url]

      if resolved_version.nil?
        puts("Unable to locate the current version for #{name} (#{repository_url})")
        next
      end

      {
        cache_key: version_tags_cache_key(normalized_url, repository_url),
        kind: requirement["kind"],
        name:,
        normalized_url:,
        repository_url:,
        requirement:,
        resolved_version:,
        source:
      }
    }
  end

  def ensure_repository_host_allowed!(name, repository_url, source)
    return if @allow_hosts.nil? || @allow_hosts.empty?

    host = GitOperations.host(repository_url)
    return if host && @allow_hosts.include?(host)

    source_note = source ? " from #{source}" : ""
    host_note = host || "unknown host"
    raise(
      DisallowedRepositoryHost,
      "Repository host #{host_note.inspect} for #{name}#{source_note} is not allowed by allow-hosts (allowed: #{@allow_hosts.join(', ')})"
    )
  end

  def ensure_repository_host_allowed(name, repository_url, source)
    ensure_repository_host_allowed!(name, repository_url, source)
    true
  rescue DisallowedRepositoryHost
    false
  end

  def version_tags_cache_key(normalized_url, repository_url)
    "#{normalized_url}\n#{repository_url}"
  end

  def prefetch_version_tags(packages)
    pending = packages.each_with_object({}) { |package, lookups|
      next unless version_tag_lookup_required?(package[:kind])
      next if @version_tags_cache.key?(package[:cache_key])

      lookups[package[:cache_key]] ||= package[:repository_url]
    }.to_a
    return if pending.empty?

    queue = Queue.new
    pending.each { |lookup| queue << lookup }

    results = {}
    results_mutex = Mutex.new
    worker_count = [VERSION_TAG_WORKER_COUNT, pending.size].min
    workers = Array.new(worker_count) {
      Thread.new {
        loop {
          begin
            cache_key, repository_url = queue.pop(true)
            versions = GitOperations.version_tags(repository_url)
            results_mutex.synchronize { results[cache_key] = versions }
          rescue ThreadError
            break
          end
        }
      }
    }

    workers.each(&:value)
    @version_tags_cache.merge!(results)
  end

  def version_tag_lookup_required?(kind)
    return false if kind == "branch"
    return @check_revisions if kind == "revision"
    return @check_when_exact if kind == "exactVersion"

    true
  end

  def version_tags_for(package)
    @version_tags_cache.fetch(package[:cache_key], [])
  end

  def check_versioned_package(kind, name, normalized_url, repository_url, requirement, resolved_version, source, available_versions = nil)
    return if kind == "exactVersion" && !@check_when_exact

    available_versions ||= GitOperations.version_tags(repository_url)
    return if available_versions.empty?
    return if available_versions.first.to_s == resolved_version

    case kind
    when "exactVersion"
      warn_for_new_versions_exact(available_versions, name, normalized_url, repository_url, resolved_version, source)
    when "upToNextMajorVersion"
      warn_for_new_versions(:major, available_versions, name, normalized_url, repository_url, resolved_version, source)
    when "upToNextMinorVersion"
      warn_for_new_versions(:minor, available_versions, name, normalized_url, repository_url, resolved_version, source)
    when "versionRange"
      warn_for_new_versions_range(available_versions, name, normalized_url, repository_url, requirement, resolved_version, source)
    else
      puts("Not processing dependency rule '#{kind}' for #{name} (#{repository_url})")
    end
  end

  def add_warning(message, source = nil, detail = nil)
    full_message = source.nil? ? message : "#{message}\nSource: #{source}"
    @warnings << full_message
    @warning_details << warning_detail_record(message, source, detail)
    puts("WARNING: #{message}#{source ? " (#{source})" : ''}")
  end

  def warning_detail_record(message, source, detail)
    record = detail ? detail.merge(message:, source:) : { message:, source: }
    record.compact
  end

  def warning_detail(type, name, normalized_url, repository_url, resolved_version, available_version, note = nil)
    {
      type: type.to_s,
      package: name,
      normalized_url:,
      repository_url:,
      current_version: resolved_version.to_s,
      available_version: available_version.to_s,
      note:
    }
  end

  # Warns if the branch has a newer commit than the resolved version.
  # @param branch [String] the branch name
  # @param name [String] the dependency name
  # @param repository_url [String] the Git repository URL
  # @param resolved_version [String] the currently resolved version of the branch
  # @param source [String, nil] the originating manifest, when applicable
  def warn_for_branch(branch, name, normalized_url, repository_url, resolved_version, source = nil)
    last_commit = GitOperations.branch_last_commit(repository_url, branch)
    return if last_commit.nil?

    add_warning(
      "Newer commit available for #{name} (#{branch}): #{last_commit}",
      source,
      warning_detail(:branch, name, normalized_url, repository_url, resolved_version, last_commit, "branch: #{branch}")
    ) unless last_commit == resolved_version
  end

  # Reports the latest tagged version for a dependency pinned to a raw revision.
  # There is no general way to know whether an arbitrary commit is behind, so
  # this is purely informational and only runs when +check_revisions+ is enabled.
  def warn_for_revision(name, normalized_url, repository_url, resolved_version, available_versions, source = nil)
    newest_version = available_versions.find { |version| @report_pre_releases ? true : version.pre.nil? }
    return if newest_version.nil?

    add_warning(
      "#{name} is pinned to a revision (#{resolved_version}); latest tagged version is #{newest_version}",
      source,
      warning_detail(:revision, name, normalized_url, repository_url, resolved_version, newest_version, "revision pin")
    )
  end

  def warn_for_new_versions_exact(available_versions, name, normalized_url, repository_url, resolved_version, source = nil)
    newest_version = available_versions.find { |version|
      @report_pre_releases ? true : version.pre.nil?
    }
    return if newest_version.nil?

    add_warning(
      "Newer version of #{name}: #{newest_version} (but this package is set to exact version #{resolved_version})",
      source,
      warning_detail(:version, name, normalized_url, repository_url, resolved_version, newest_version, "exact version")
    ) unless newest_version.to_s == resolved_version
  end

  def warn_for_new_versions_range(available_versions, name, normalized_url, repository_url, requirement, resolved_version, source = nil)
    begin
      max_version = Semantic::Version.new(requirement["maximumVersion"])
    rescue ArgumentError => e
      puts("Unable to extract semver from #{requirement} for #{name} (#{e})")
      return
    end
    # Honor the pre-release policy: never report a pre-release as the newest
    # version when report_pre_releases is false.
    newest = available_versions.find { |version| @report_pre_releases ? true : version.pre.nil? }
    return if newest.nil?

    if newest < max_version
      add_warning(
        "Newer version of #{name}: #{newest}",
        source,
        warning_detail(:version, name, normalized_url, repository_url, resolved_version, newest, "version range")
      ) unless newest.to_s == resolved_version
    else
      newest_meeting_reqs = available_versions.find { |version|
        version < max_version && (@report_pre_releases ? true : version.pre.nil?)
      }
      add_warning(
        "Newer version of #{name}: #{newest_meeting_reqs}",
        source,
        warning_detail(:version, name, normalized_url, repository_url, resolved_version, newest_meeting_reqs, "version range")
      ) unless newest_meeting_reqs.nil? || newest_meeting_reqs.to_s == resolved_version
      add_warning(
        "Newest version of #{name}: #{newest} (but this package is configured up to the next #{max_version} version)",
        source,
        warning_detail(:above_maximum, name, normalized_url, repository_url, resolved_version, newest, "above configured maximum")
      ) if @report_above_maximum
    end
  end

  def warn_for_new_versions(major_or_minor, available_versions, name, normalized_url, repository_url, resolved_version_string, source = nil)
    begin
      resolved_version = Semantic::Version.new(resolved_version_string)
    rescue ArgumentError => e
      puts("Unable to extract semver from #{resolved_version_string} for #{name} (#{e})")
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

    add_warning(
      "Newer version of #{name}: #{newest_meeting_reqs}",
      source,
      warning_detail(:version, name, normalized_url, repository_url, resolved_version, newest_meeting_reqs, "up to next #{major_or_minor}")
    ) unless newest_meeting_reqs.nil? || newest_meeting_reqs == resolved_version
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
      source,
      warning_detail(:above_maximum, name, normalized_url, repository_url, resolved_version, newest_above_reqs, "above configured maximum")
    ) unless newest_above_reqs == newest_meeting_reqs
  end
end
