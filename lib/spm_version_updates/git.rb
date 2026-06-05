# frozen_string_literal: true

require "open3"

module Git
  # Removes protocol and trailing .git from a repo URL
  # @param   [String] repo_url
  #          The URL of the repository
  # @return [String]
  def self.trim_repo_url(repo_url)
    repo_url.split("://").last.gsub(/\.git$/, "")
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

  # Call git to list tags
  # @param   [String] repo_url
  #          The URL of the dependency's repository
  # @return [Array<Semantic::Version>]
  def self.version_tags(repo_url)
    versions = ls_remote("-t", repo_url)
      .split("\n")
      .map { |line| line.split("/tags/").last }
      .filter_map { |line|
        begin
          Semantic::Version.new(line)
        rescue ArgumentError
          nil
        end
      }
    versions.sort!.reverse!
    versions
  end

  # Call git to find the last commit on a branch
  # @param   [String] repo_url
  #          The URL of the dependency's repository
  # @param   [String] branch_name
  #          The name of the branch on which to find the last commit
  # @return [String]
  def self.branch_last_commit(repo_url, branch_name)
    ls_remote("-h", repo_url)
      .split("\n")
      .find { |line| line.split("\trefs/heads/")[1] == branch_name }
      &.split("\trefs/heads/")&.first
  end

  def self.ls_remote(flag, repo_url)
    stdout, _stderr, status = Open3.capture3("git", "ls-remote", flag, repo_url)
    return stdout if status.success?

    ""
  rescue Errno::ENOENT
    ""
  end

  private_class_method :ls_remote
end
