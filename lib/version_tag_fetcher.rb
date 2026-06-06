# frozen_string_literal: true

require_relative "git_operations"

# Fetches git tag versions concurrently for cache-key/repository URL lookup pairs.
class VersionTagFetcher
  def self.call(lookups, worker_limit:)
    new(lookups, worker_limit).call
  end

  def initialize(lookups, worker_limit)
    @lookups = lookups
    @worker_limit = worker_limit
    @mutex = Mutex.new
    @results = {}
  end

  def call
    queue = build_queue
    workers(queue).each(&:value)
    @results
  end

  private

  def build_queue
    Queue.new.tap { |queue| @lookups.each { |lookup| queue << lookup } }
  end

  def workers(queue)
    Array.new(worker_count) { Thread.new { drain_queue(queue) } }
  end

  def worker_count
    [@worker_limit, @lookups.size].min
  end

  def drain_queue(queue)
    loop { fetch_lookup(queue) }
  rescue ThreadError
    nil
  end

  def fetch_lookup(queue)
    cache_key, repository_url = queue.pop(true)
    versions = GitOperations.version_tags(repository_url)
    @mutex.synchronize { @results[cache_key] = versions }
  end
end
