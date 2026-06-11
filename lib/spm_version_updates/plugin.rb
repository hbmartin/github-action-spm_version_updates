# frozen_string_literal: true

require_relative "../manifest_parser"
require_relative "../repository_link"
require_relative "../repository_update_rules"
require_relative "../spm_checker"
require_relative "git"
require_relative "semver"
require_relative "xcode"

module Danger
  # A Danger plugin for checking if there are versions upgrades available for SPM dependencies
  #
  # @example Check if MyApp's SPM dependencies are up to date
  #          spm_version_updates.check_for_updates("MyApp.xcodeproj")
  #
  # @example Check dependencies declared in Package.swift manifests
  #          spm_version_updates.check_manifests(["Modules/Package.swift"])
  #
  # @see  hbmartin/danger-spm_version_updates
  # @tags swift, spm, swift package manager, xcode, xcodeproj, version, updates
  #
  class DangerSpmVersionUpdates < Plugin
    # Whether to check when dependencies are exact versions or commits, default false
    # @return   [Boolean]
    attr_accessor :check_when_exact

    # Whether to check dependencies pinned to a branch for newer commits, default true
    # @return   [Boolean]
    attr_accessor :check_branches

    # Whether to report the latest tagged version for dependencies pinned to a revision, default false
    # @return   [Boolean]
    attr_accessor :check_revisions

    # Whether to report versions above the maximum version range, default false
    # @return   [Boolean]
    attr_accessor :report_above_maximum

    # Whether to report pre-release versions, default false
    # @return   [Boolean]
    attr_accessor :report_pre_releases

    # A list of repository URLs for packages to ignore entirely
    # @return   [Array<String>]
    attr_accessor :ignore_repos

    # Path to a YAML file with per-repository semantic update suppression rules
    # @return   [String]
    attr_accessor :repo_rules_path

    # A method that you can call from your Dangerfile
    # @param   [String] xcodeproj_path
    #          The path to your Xcode project
    # @raise [Xcode::XcodeprojPathMustBeSet] if the xcodeproj_path is blank
    # @raise [Xcode::CouldNotFindResolvedFile] if no Package.resolved files were found
    # @return   [void]
    def check_for_updates(xcodeproj_path)
      run_checker { |checker| checker.check_for_updates(xcodeproj_path) }
    end

    # Check for updates to dependencies declared in one or more Package.swift manifests
    # @param   [Array<String>, String] manifest_paths
    #          One or more paths to Package.swift manifests
    # @param   [Array<String>, String, nil] resolved_paths
    #          Optional explicit Package.resolved paths; defaults to a
    #          Package.resolved next to each manifest
    # @raise [ManifestParser::ManifestPathMustBeSet] if manifest_paths is blank
    # @raise [ManifestParser::CouldNotFindManifest] if a manifest does not exist
    # @raise [ManifestParser::CouldNotFindResolvedFile] if an expected Package.resolved is missing
    # @return   [void]
    def check_manifests(manifest_paths, resolved_paths = nil)
      paths = Array(manifest_paths).map(&:to_s).reject(&:empty?)
      raise(ManifestParser::ManifestPathMustBeSet) if paths.empty?

      run_checker { |checker| checker.check_manifests(paths, Array(resolved_paths)) }
    end

    private

    def run_checker
      checker = build_checker
      yield(checker)
      emit_checker_warnings(checker)
    end

    def build_checker
      SpmChecker.new.tap { |checker|
        copy_accessors(checker)
        checker.repository_update_rules = repository_update_rules
        checker.lookup_failure_handler = method(:warn_lookup_failure)
        checker.malformed_resolved_handler = method(:warn_malformed_resolved)
      }
    end

    def copy_accessors(checker)
      checker.check_when_exact = check_when_exact
      checker.check_branches = check_branches != false
      checker.check_revisions = check_revisions
      checker.report_above_maximum = report_above_maximum
      checker.report_pre_releases = report_pre_releases
      checker.ignore_repos = Array(ignore_repos)
    end

    def emit_checker_warnings(checker)
      checker.warning_details.each { |detail| warn(render_warning(detail)) }
    end

    # Builds the Danger warning markdown for one structured warning detail:
    # message, compare/release links when the host is supported, and the
    # originating manifest. Uses <br> rather than newlines because Danger
    # renders warnings inside a markdown table.
    def render_warning(detail)
      message = detail[:message]
      links = warning_links(detail)
      message = "#{message} (#{links})" if links

      source = detail[:source]
      message = "#{message}<br>Source: `#{source}`" if source

      command = detail[:suggested_command]
      command ? "#{message}<br>Update: `#{command}`" : message
    end

    def warning_links(detail)
      link = RepositoryLink.from(detail[:repository_url])
      return unless link

      current, available = detail.values_at(:current_version, :available_version)
      return unless current && available

      link.markdown_links([{ current:, available: }], separator: " · ")
    end

    # Emits a Danger warning for a package whose remote lookup failed.
    # @param package [SpmPackageContext] the package whose lookup failed
    # @param error [GitOperations::LsRemoteError] the lookup failure
    def warn_lookup_failure(package, error)
      warn("Unable to check #{package.name} (#{package.normalized_url}) for updates: #{error.message}")
    end

    # Emits a Danger warning for a Package.resolved file that could not be parsed.
    # @param resolved_path [String] the malformed file
    # @param error [PackageResolved::MalformedFileError] the parse failure
    def warn_malformed_resolved(resolved_path, error)
      warn("Skipping malformed Package.resolved file #{resolved_path}: #{error.message}")
    end

    def repository_update_rules
      repo_rules_path ? RepositoryUpdateRules.load_file(repo_rules_path) : RepositoryUpdateRules.empty
    end
  end
end
