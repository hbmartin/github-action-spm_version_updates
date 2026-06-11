# frozen_string_literal: true

require_relative "../git_operations"
require_relative "semver"

# Legacy git helper used by the Danger plugin API. Delegates to GitOperations,
# so lookups gain its retry behavior and raise GitOperations::LsRemoteError
# instead of masking failures as empty results.
module Git
  ALLOWED_PROTOCOLS = GitOperations::ALLOWED_PROTOCOLS

  # Removes protocol and trailing .git from a repo URL
  # @param   [String] repo_url
  #          The URL of the repository
  # @return [String]
  def self.trim_repo_url(repo_url)
    GitOperations.trim_repo_url(repo_url)
  end

  # Extract a readable name for the repo given the url, generally org/repo
  # @return [String]
  def self.repo_name(repo_url)
    GitOperations.repo_name(repo_url)
  end

  # Call git to list tags
  # @param   [String] repo_url
  #          The URL of the dependency's repository
  # @raise [GitOperations::LsRemoteError] if the lookup fails after retries
  # @return [Array<SpmVersionUpdates::Semver>]
  def self.version_tags(repo_url)
    GitOperations.version_tags(repo_url)
  end

  # Call git to find the last commit on a branch
  # @param   [String] repo_url
  #          The URL of the dependency's repository
  # @param   [String] branch_name
  #          The name of the branch on which to find the last commit
  # @raise [GitOperations::LsRemoteError] if the lookup fails after retries
  # @return [String, nil]
  def self.branch_last_commit(repo_url, branch_name)
    GitOperations.branch_last_commit(repo_url, branch_name)
  end
end
