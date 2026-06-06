# frozen_string_literal: true

require_relative "git_operations"

# Carries normalized package facts through version, branch, and revision checks.
SpmPackageContext = Struct.new(
  :cache_key,
  :kind,
  :name,
  :normalized_url,
  :repository_url,
  :persistent_cache_key,
  :requirement,
  :resolved_version,
  :source,
  keyword_init: true
) {
  def add_version_tag_lookup(lookups, cache)
    key = cache_key
    lookups[key] ||= [cache_key, repository_url, persistent_cache_key] unless cache.key?(key)
  end

  def branch
    requirement["branch"]
  end

  def branch_update?(last_commit)
    last_commit && last_commit != resolved_version
  end

  def branch_warning_message(last_commit)
    "Newer commit available for #{name} (#{branch}): #{last_commit}"
  end

  def branch_update_warning
    last_commit = GitOperations.branch_last_commit(repository_url, branch)
    return unless branch_update?(last_commit)

    [branch_warning_message(last_commit), last_commit, "branch: #{branch}"]
  end

  def source_line
    "Source: #{source}" if source
  end

  def source_suffix
    source ? " (#{source})" : ""
  end
}
