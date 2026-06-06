# frozen_string_literal: true

require "open3"
require_relative "credential_redactor"
require_relative "git_host_normalizer"
require_relative "spm_version_updates/semver"

# Git operations for SPM version checking (migrated from git.rb)
module GitOperations
  ALLOWED_PROTOCOLS = "https:ssh:git"
  HOST_PATTERN = GitHostNormalizer::HOST_PATTERN

  # Removes protocol and trailing .git from a repo URL
  # @param   [String] repo_url The URL of the repository
  # @return [String]
  def self.trim_repo_url(repo_url)
    url = repo_url.to_s.strip
    return "" if url.empty?

    url.split("://").last.gsub(/\.git$/, "")
  end

  # Extract a readable name for the repo given the url, generally org/repo
  # @return [String]
  def self.repo_name(repo_url)
    match = repo_url.match(%r{([\w-]+/[\w-]+)(.git)?$})
    if match
      match[1] || match[0]
    else
      repo_url
    end
  end

  # Extracts the hostname from common git remote URL forms.
  # @return [String, nil]
  def self.host(repo_url)
    GitHostNormalizer.host(repo_url)
  end

  # Call git to list tags
  # @param   [String] repo_url The URL of the dependency's repository
  # @return [Array<SpmVersionUpdates::Semver>]
  def self.version_tags(repo_url)
    output = ls_remote("-t", repo_url)
    return [] if output.nil?

    versions = output
      .split("\n")
      .map { |line| line.split("/tags/").last }
      .filter_map { |line|
        begin
          SpmVersionUpdates::Semver.new(line)
        rescue ArgumentError
          nil
        end
      }
    versions.sort!.reverse!
    versions
  end

  # Call git to find the last commit on a branch
  # @param   [String] repo_url The URL of the dependency's repository
  # @param   [String] branch_name The name of the branch on which to find the last commit
  # @return [String, nil]
  def self.branch_last_commit(repo_url, branch_name)
    output = ls_remote("-h", repo_url)
    return nil if output.nil?

    line = output
      .split("\n")
      .find { |remote_ref| remote_ref.split("\trefs/heads/")[1] == branch_name }
    line&.split("\trefs/heads/")&.first
  end

  # Run `git ls-remote` with +flag+ against +repo_url+ using an argument vector
  # (no shell), so repository URLs are never word-split or interpreted by a
  # shell. Returns git's stdout on success, or nil when the command exits
  # non-zero -- logging git's stderr clearly instead of masking the failure as
  # an empty result (which previously made every failed lookup look like
  # "no updates available").
  # @return [String, nil]
  def self.ls_remote(flag, repo_url)
    stdout, stderr, status = Open3.capture3(
      { "GIT_ALLOW_PROTOCOL" => ALLOWED_PROTOCOLS },
      "git",
      "ls-remote",
      flag,
      "--",
      repo_url
    )
    return stdout if status.success?

    warn("git ls-remote #{flag} failed for #{redact_credentials(repo_url)}: #{redact_credentials(stderr.strip)}")
    nil
  rescue Errno::ENOENT
    warn("git command not found. Please ensure git is installed and available in your PATH.")
    nil
  end

  def self.redact_credentials(value)
    CredentialRedactor.redact(value)
  end

  private_class_method :ls_remote, :redact_credentials
end
