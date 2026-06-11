# frozen_string_literal: true

require "open3"
require_relative "credential_redactor"
require_relative "git_host_normalizer"
require_relative "semver"

# Git operations for SPM version checking (migrated from git.rb)
module GitOperations
  ALLOWED_PROTOCOLS = "https:ssh:git"
  LS_REMOTE_RETRY_DELAYS = [0.25, 0.5].freeze
  NON_INTERACTIVE_ENV = {
    "GIT_ALLOW_PROTOCOL" => ALLOWED_PROTOCOLS,
    "GIT_TERMINAL_PROMPT" => "0"
  }.freeze
  TAG_REF_PATTERNS = ["[0-9]*.[0-9]*", "v[0-9]*.[0-9]*"].freeze

  # Raised when git cannot complete a remote reference lookup.
  class LsRemoteError < StandardError; end

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
    output = ls_remote(repo_url, options: ["--tags", "--refs"], patterns: TAG_REF_PATTERNS)

    versions = output
      .split("\n")
      .filter_map { |line| tag_name(line) }
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
    branch_ref = "refs/heads/#{branch_name}"
    output = ls_remote(repo_url, options: ["--branches"], patterns: [branch_ref])

    line = output
      .split("\n")
      .find { |remote_ref| remote_ref.split("\t")[1] == branch_ref }
    line&.split("\t")&.first
  end

  # Run `git ls-remote` with an argument vector (no shell), so repository URLs
  # are never word-split or interpreted by a shell. Raises after bounded retries
  # instead of masking network/auth failures as "no updates available".
  # @return [String]
  def self.ls_remote(repo_url, options:, patterns: [])
    attempts = 0
    stdout = nil
    stderr = nil

    loop {
      attempts += 1
      stdout, stderr, status = capture_ls_remote(repo_url, options, patterns)
      return stdout if status.success?

      break if attempts >= ls_remote_attempts

      sleep(LS_REMOTE_RETRY_DELAYS.fetch(attempts - 1))
    }

    raise_ls_remote_error(failure_message(repo_url, stderr, attempts))
  rescue Errno::ENOENT
    raise_ls_remote_error("git command not found. Please ensure git is installed and available in your PATH.")
  rescue SystemCallError => error
    raise_ls_remote_error("git ls-remote failed to start: #{error.message}")
  end

  def self.ls_remote_attempts
    LS_REMOTE_RETRY_DELAYS.size + 1
  end

  def self.capture_ls_remote(repo_url, options, patterns)
    Open3.capture3(
      NON_INTERACTIVE_ENV,
      "git",
      "ls-remote",
      *options,
      "--",
      repo_url,
      *patterns
    )
  end

  def self.failure_message(repo_url, stderr, attempts)
    details = stderr.to_s.strip
    details = "no stderr" if details.empty?
    "git ls-remote failed for #{redact_credentials(repo_url)} after #{attempts} attempts: #{redact_credentials(details)}"
  end

  def self.raise_ls_remote_error(message)
    warn(message)
    raise(LsRemoteError, message)
  end

  def self.tag_name(line)
    line[%r{\A[^\t]+\trefs/tags/(.+)\z}, 1]
  end

  def self.redact_credentials(value)
    CredentialRedactor.redact(value)
  end

  private_class_method :ls_remote,
                       :ls_remote_attempts,
                       :capture_ls_remote,
                       :failure_message,
                       :raise_ls_remote_error,
                       :tag_name,
                       :redact_credentials
end
