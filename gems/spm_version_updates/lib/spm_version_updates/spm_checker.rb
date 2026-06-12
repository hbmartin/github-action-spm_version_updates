# frozen_string_literal: true

require_relative "allow_host_normalizer"
require_relative "credential_redactor"
require_relative "errors"
require_relative "git_operations"
require_relative "manifest_parser"
require_relative "package_resolved"
require_relative "parse_warning"
require_relative "repository_update_rules"
require_relative "semver"
require_relative "spm_package_context"
require_relative "upgrade_suggestion"
require_relative "version_tag_fetcher"
require_relative "version_tags_persistent_cache"
require_relative "xcode_parser"

# Core SPM version checking logic (migrated from Danger plugin)
class SpmChecker
  VERSION_TAG_WORKER_COUNT = 8

  # Raised when allow-hosts blocks a repository before git is contacted.
  class DisallowedRepositoryHost < SpmVersionUpdates::PolicyError; end

  # Structured facts about each warning, used by the GitHub Action comment
  # renderer. `check_for_updates` and `check_manifests` still return the legacy
  # string warnings for compatibility with existing plugin-style callers.
  attr_reader :warning_details

  # ParseWarning records for `.package(...)` declarations the manifest parser
  # had to skip. Kept separate from update warnings so reported update counts
  # and fail-on thresholds are unaffected.
  attr_reader :parse_warnings

  attr_accessor :allow_hosts,
                :check_branches,
                :check_revisions,
                :check_when_exact,
                :ignore_repos,
                :repository_update_rules,
                :report_above_maximum,
                :report_pre_releases,
                :version_tags_cache_dir,
                :version_tags_cache_ttl_seconds

  # Optional callable `(package, error)` invoked instead of raising when a git
  # lookup fails, so callers like the Danger plugin can warn and keep checking
  # the remaining packages. When nil (the default), lookup failures raise one
  # combined GitOperations::LsRemoteError exactly as before.
  attr_accessor :lookup_failure_handler

  # Optional callable `(resolved_path, error)` invoked instead of raising when a
  # Package.resolved file is malformed; the file is skipped. When nil (the
  # default), PackageResolved::MalformedFileError is raised.
  attr_accessor :malformed_resolved_handler

  def self.redact_credentials(value)
    CredentialRedactor.redact(value)
  end

  def initialize
    @check_when_exact = @check_revisions = @report_above_maximum = @report_pre_releases = false
    @check_branches = true
    @lookup_failure_handler = @malformed_resolved_handler = nil
    @ignore_repos = []
    @repository_update_rules = RepositoryUpdateRules.empty
    @allow_hosts = []
    @warnings = []
    @warning_details = []
    @parse_warnings = []
    @version_tags_cache = {}
    @version_tag_lookup_errors = {}
    @reported_lookup_failures = {}
    @version_tags_cache_dir = nil
    @version_tags_cache_ttl_seconds = VersionTagsPersistentCache::DEFAULT_TTL_SECONDS
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
    resolved_versions = XcodeParser.get_resolved_versions(xcodeproj_path, &@malformed_resolved_handler)
    puts("Found resolved versions for #{resolved_versions.size} packages")
    warn_for_empty_xcode_project(remote_packages, resolved_versions, xcodeproj_path)

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
      check_packages(manifest_packages(manifest_path), resolved_versions, manifest_path)
    }
    @warnings
  end

  private

  def manifest_packages(manifest_path)
    ManifestParser.get_packages(manifest_path) { |skip| record_parse_warning(skip, manifest_path) }
  end

  def normalize_ignore_repos
    @ignore_repos = Array(@ignore_repos).map { |repo| GitOperations.trim_repo_url(repo) }
  end

  def normalize_allow_hosts
    raw_allow_hosts = configured_allow_hosts
    @allow_hosts = raw_allow_hosts.filter_map { |host| AllowHostNormalizer.normalize(host) }
    return unless invalid_allow_hosts_configuration?(raw_allow_hosts)

    raise(SpmVersionUpdates::ConfigurationError, "allow-hosts was configured, but no entries could be parsed as hostnames")
  end

  def configured_allow_hosts
    AllowHostNormalizer.configured_entries(@allow_hosts)
  end

  def invalid_allow_hosts_configuration?(raw_allow_hosts)
    raw_allow_hosts.any? && @allow_hosts.empty?
  end

  def clear_warnings
    @warnings.clear
    @warning_details.clear
    @parse_warnings.clear
  end

  def record_parse_warning(skip, manifest_path)
    record = ParseWarning.record(**skip, source: manifest_path)
    @parse_warnings << record
    puts("WARNING: #{record['message']}")
  end

  def warn_for_empty_xcode_project(remote_packages, resolved_versions, xcodeproj_path)
    return unless remote_packages.empty? && !resolved_versions.empty?

    puts(
      "WARNING: No XCRemoteSwiftPackageReference entries were found in #{xcodeproj_path}, " \
      "but Package.resolved contains resolved packages. If dependencies are declared in " \
      "Package.swift files, use package-manifest-paths instead."
    )
  end

  def reset_version_tags_cache
    @version_tags_cache = {}
    @version_tag_lookup_errors = {}
    @reported_lookup_failures = {}
  end

  # Merge the resolved pins of every relevant `Package.resolved` file.
  #
  # Every expected resolved file must exist. A missing one would silently drop a
  # manifest's pins and produce misleading "all up to date" results, so we fail
  # loudly and name the missing file(s) instead.
  #
  # @return [Hash<String, String>]
  def merged_resolved_versions(manifest_paths, resolved_paths)
    paths = Array(resolved_paths).map(&:to_s).reject(&:empty?)
    paths = manifest_paths.map { |manifest| ManifestParser.default_resolved_path(manifest) } if paths.empty?

    missing = paths.reject { |path| File.exist?(path) }
    raise(ManifestParser::CouldNotFindResolvedFile, missing.join(", ")) unless missing.empty?

    puts("Reading resolved packages from: #{paths}")
    paths.each_with_object({}) { |path, pins| pins.merge!(resolved_versions_from(path)) }
  end

  def resolved_versions_from(path)
    PackageResolved.versions_from(path)
  rescue PackageResolved::MalformedFileError => error
    raise unless @malformed_resolved_handler

    @malformed_resolved_handler.call(path, error)
    {}
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
      lookup_error = @version_tag_lookup_errors[package.cache_key]
      if lookup_error
        raise(lookup_error) unless @lookup_failure_handler

        next report_lookup_failure(package, lookup_error)
      end

      check_package_handling_lookup_failure(package)
    }
  end

  def check_package_handling_lookup_failure(package)
    check_package(package)
  rescue GitOperations::LsRemoteError => error
    raise unless @lookup_failure_handler

    @version_tag_lookup_errors[package.cache_key] = error
    report_lookup_failure(package, error)
  end

  # A dependency shared by several manifests fails its lookup once per run:
  # the error is cached so it is never re-fetched, and reported to the handler
  # only the first time it is seen.
  def report_lookup_failure(package, error)
    key = package.cache_key
    return if @reported_lookup_failures.key?(key)

    @reported_lookup_failures[key] = true
    @lookup_failure_handler.call(package, error)
  end

  def package_contexts(remote_packages, resolved_versions, source)
    remote_packages.filter_map { |normalized_url, entry|
      next if @ignore_repos.include?(normalized_url)

      repository_url = entry["repository_url"]
      requirement = entry["requirement"]
      next unless requirement

      name = GitOperations.repo_name(normalized_url)

      resolved_version = resolved_versions[normalized_url]

      unless resolved_version
        puts("Unable to locate the current version for #{name} (#{self.class.redact_credentials(repository_url)})")
        next
      end

      kind = requirement["kind"]
      validate_repository_host(name, repository_url, source) if git_lookup_required?(kind)

      SpmPackageContext.new(
        cache_key: version_tags_cache_key(normalized_url, repository_url),
        kind:,
        name:,
        normalized_url:,
        repository_url:,
        persistent_cache_key: VersionTagsPersistentCache.cache_key(normalized_url, repository_url),
        requirement:,
        resolved_version:,
        source:
      )
    }
  end

  def validate_repository_host(name, repository_url, source)
    return if @allow_hosts.empty?

    host = GitOperations.host(repository_url)
    return if host && @allow_hosts.include?(host)

    raise(DisallowedRepositoryHost, disallowed_repository_host_message(name, source, host || "unknown host"))
  end

  def disallowed_repository_host_message(name, source, host_note)
    source_note = source ? " from #{source}" : ""
    "Repository host #{host_note.inspect} for #{name}#{source_note} is not allowed by allow-hosts (allowed: #{@allow_hosts.join(', ')})"
  end

  def version_tags_cache_key(normalized_url, repository_url)
    "#{normalized_url}\n#{repository_url}"
  end

  # Failed lookups land in @version_tag_lookup_errors keyed by cache key
  # (always empty when no lookup_failure_handler is configured -- failures
  # raise instead).
  def prefetch_version_tags(packages)
    pending = pending_version_tag_lookups(packages)
    return if pending.empty?

    persistent_cache = VersionTagsPersistentCache.new(directory: @version_tags_cache_dir, ttl_seconds: @version_tags_cache_ttl_seconds)
    results, errors = VersionTagFetcher.call(
      pending,
      worker_limit: VERSION_TAG_WORKER_COUNT,
      persistent_cache:,
      raise_on_error: !@lookup_failure_handler
    )
    @version_tags_cache.merge!(results)
    @version_tag_lookup_errors.merge!(errors)
  end

  def pending_version_tag_lookups(packages)
    packages.each_with_object({}) { |package, lookups|
      next unless version_tag_lookup_required?(package.kind)
      next if @version_tag_lookup_errors.key?(package.cache_key)

      package.add_version_tag_lookup(lookups, @version_tags_cache)
    }.values
  end

  def version_tag_lookup_required?(kind)
    {
      "branch" => false,
      "revision" => @check_revisions,
      "exactVersion" => @check_when_exact
    }.fetch(kind, true)
  end

  def git_lookup_required?(kind)
    return @check_branches if kind == "branch"

    version_tag_lookup_required?(kind)
  end

  def version_tags_for(package)
    @version_tags_cache.fetch(package.cache_key, [])
  end

  def newest_reportable_version(available_versions)
    available_versions.find { |version| reportable_version?(version) }
  end

  def reportable_version?(version)
    @report_pre_releases || !version.pre
  end

  def check_package(package)
    available_versions = version_tags_for(package)

    case package.kind
    when "branch"
      warn_for_branch(package) if @check_branches
    when "revision"
      warn_for_revision(package, available_versions) if @check_revisions
    else
      check_versioned_package(package, available_versions)
    end
  end

  def check_versioned_package(package, available_versions = nil)
    kind = package.kind
    repository_url = package.repository_url
    return if kind == "exactVersion" && !@check_when_exact

    available_versions ||= GitOperations.version_tags(repository_url)
    return if available_versions.empty?
    return if available_versions.first.to_s == package.resolved_version

    case kind
    when "exactVersion"
      warn_for_new_versions_exact(package, available_versions)
    when "upToNextMajorVersion"
      warn_for_new_versions(package, available_versions, :major)
    when "upToNextMinorVersion"
      warn_for_new_versions(package, available_versions, :minor)
    when "versionRange"
      warn_for_new_versions_range(package, available_versions)
    else
      puts("Not processing dependency rule '#{kind}' for #{package.name} (#{self.class.redact_credentials(repository_url)})")
    end
  end

  def add_warning(message, package, detail)
    record = warning_detail_record(message, package, detail)
    return if @repository_update_rules.suppressed?(record)

    record_warning(message, package, record)
  end

  def record_warning(message, package, record)
    @warnings << [message, package.source_line].compact.join("\n")
    @warning_details << record
    puts("WARNING: #{message}#{package.source_suffix}")
  end

  def warning_detail_record(message, package, detail)
    detail.merge(message:, source: package.source).compact
  end

  def warning_detail(type, package, available_version, note = nil)
    {
      type: type.to_s,
      package: package.name,
      normalized_url: package.normalized_url,
      repository_url: package.repository_url,
      current_version: package.resolved_version.to_s,
      available_version: available_version.to_s,
      note:
    }.merge(UpgradeSuggestion.fields(package, available_version, type))
  end

  # Warns if the branch has a newer commit than the resolved version.
  def warn_for_branch(package)
    warning = package.branch_update_warning
    return unless warning

    message, last_commit, note = warning

    add_warning(
      message,
      package,
      warning_detail(:branch, package, last_commit, note)
    )
  end

  # Reports the latest tagged version for a dependency pinned to a raw revision.
  # There is no general way to know whether an arbitrary commit is behind, so
  # this is purely informational and only runs when +check_revisions+ is enabled.
  def warn_for_revision(package, available_versions)
    newest_version = newest_reportable_version(available_versions)
    return unless newest_version

    add_warning(
      "#{package.name} is pinned to a revision (#{package.resolved_version}); latest tagged version is #{newest_version}",
      package,
      warning_detail(:revision, package, newest_version, "revision pin")
    )
  end

  def warn_for_new_versions_exact(package, available_versions)
    resolved_version = package.resolved_version
    newest_version = newest_reportable_version(available_versions)
    return unless newest_version
    return if newest_version.to_s == resolved_version

    add_warning(
      "Newer version of #{package.name}: #{newest_version} (but this package is set to exact version #{resolved_version})",
      package,
      warning_detail(:version, package, newest_version, "exact version")
    )
  end

  def warn_for_new_versions_range(package, available_versions)
    name = package.name
    requirement = package.requirement
    resolved_version = package.resolved_version

    begin
      max_version = SpmVersionUpdates::Semver.new(requirement["maximumVersion"])
    rescue ArgumentError => error
      puts("Unable to extract semver from #{requirement} for #{name} (#{error})")
      return
    end
    # Honor the pre-release policy: never report a pre-release as the newest
    # version when report_pre_releases is false.
    newest = newest_reportable_version(available_versions)
    return unless newest

    if newest < max_version
      unless newest.to_s == resolved_version
        add_warning(
          "Newer version of #{name}: #{newest}",
          package,
          warning_detail(:version, package, newest, "version range")
        )
      end
    else
      newest_meeting_reqs = available_versions.find { |version|
        version < max_version && reportable_version?(version)
      }
      unless newest_meeting_reqs.nil? || newest_meeting_reqs.to_s == resolved_version
        add_warning(
          "Newer version of #{name}: #{newest_meeting_reqs}",
          package,
          warning_detail(:version, package, newest_meeting_reqs, "version range")
        )
      end
      if @report_above_maximum
        add_warning(
          "Newest version of #{name}: #{newest} (but this package is configured up to the next #{max_version} version)",
          package,
          warning_detail(:above_maximum, package, newest, "above configured maximum")
        )
      end
    end
  end

  def warn_for_new_versions(package, available_versions, major_or_minor)
    name = package.name
    resolved_version_string = package.resolved_version

    begin
      resolved_version = SpmVersionUpdates::Semver.new(resolved_version_string)
    rescue ArgumentError => error
      puts("Unable to extract semver from #{resolved_version_string} for #{name} (#{error})")
      return
    end
    # upToNextMajor allows any version with the same major; upToNextMinor additionally
    # requires the same minor. Comparing minor alone would wrongly match e.g. 2.5.0
    # against a resolved 1.5.0.
    newest_meeting_reqs = available_versions.find { |version|
      version.major == resolved_version.major &&
        (major_or_minor == :major || version.minor == resolved_version.minor) &&
        reportable_version?(version)
    }

    unless newest_meeting_reqs.nil? || newest_meeting_reqs == resolved_version
      add_warning(
        "Newer version of #{name}: #{newest_meeting_reqs}",
        package,
        warning_detail(:version, package, newest_meeting_reqs, "up to next #{major_or_minor}")
      )
    end
    return unless @report_above_maximum

    newest_above_reqs = newest_reportable_version(available_versions)
    # Suppressed only when nothing exists above the constraint (the newest overall
    # is the newest in-constraint version). Being at the newest in-constraint
    # version is intentionally still reported here, since report_above_maximum
    # exists precisely to surface the out-of-range (e.g. next major) version.
    return if newest_above_reqs == newest_meeting_reqs

    add_warning(
      "Newest version of #{name}: #{newest_above_reqs} (but this package is configured up to the next #{major_or_minor} version)",
      package,
      warning_detail(:above_maximum, package, newest_above_reqs, "above configured maximum")
    )
  end
end
