# frozen_string_literal: true

require "open3"
require "semantic"
require "uri"

# Git operations for SPM version checking (migrated from git.rb)
module GitOperations
  ALLOWED_PROTOCOLS = "https:ssh:git"
  HOST_PATTERN = /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i

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
    url = repo_url.to_s.strip
    return nil if url.empty?

    parsed_host(url) || scp_like_host(url) || bare_host(url)
  end

  # Call git to list tags
  # @param   [String] repo_url The URL of the dependency's repository
  # @return [Array<Semantic::Version>]
  def self.version_tags(repo_url)
    output = ls_remote("-t", repo_url)
    return [] if output.nil?

    versions = output
      .split("\n")
      .map { |line| line.split("/tags/").last }
      .filter_map { |line|
        begin
          Semantic::Version.new(normalize_version_tag(line))
        rescue ArgumentError
          nil
        end
      }
    versions.sort! { |left, right| compare_semver(left, right) }
      .reverse!
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
    value.to_s.gsub(%r{([a-z][a-z0-9+\-.]*://)([^/\s@]+)@}i, '\1[REDACTED]@')
  end

  # Compare two Semantic::Version values, tolerating a bug in the `semantic` gem
  # where comparing certain pre-release identifiers raises ArgumentError -- e.g.
  # date components with a leading zero ("08"/"09"), as in swift-syntax's
  # "600.0.0-prerelease-2024-09-04" tags, which it feeds to Integer() and rejects
  # as invalid octal. Falls back to comparing the stable core, then the string
  # form, so a single odd tag can't abort the whole sort.
  # @return [Integer]
  def self.compare_semver(left, right)
    left <=> right
  rescue ArgumentError
    core = [left.major, left.minor, left.patch] <=> [right.major, right.minor, right.patch]
    core.zero? ? (left.to_s <=> right.to_s) : core
  end

  def self.normalize_version_tag(tag)
    tag.sub(/\A(\d+)\.(\d+)(?=\z|[-+])/, '\1.\2.0')
  end

  def self.parsed_host(url)
    normalize_host(URI.parse(url).host)
  rescue URI::InvalidURIError
    nil
  end

  def self.scp_like_host(url)
    match = url.match(%r{\A(?:[^@\s/]+@)?(?<host>[^:\s/]+):(?!/)[^:\s]+\z})
    match && normalize_host(match[:host])
  end

  def self.bare_host(url)
    return nil if url.start_with?("/", "./", "../")
    return nil if url.include?("://")

    host = url.split("/", 2).first
    normalize_host(host)
  end

  def self.normalize_host(host)
    normalized = host.to_s.sub(/:\d+\z/, "").downcase
    return nil if normalized.empty? || !normalized.match?(HOST_PATTERN)

    normalized
  end

  private_class_method :ls_remote, :redact_credentials, :compare_semver, :normalize_version_tag, :parsed_host, :scp_like_host, :bare_host, :normalize_host
end
