# frozen_string_literal: true

require_relative "git_operations"

# Fetches git tag versions concurrently for cache-key/repository URL lookup pairs.
class VersionTagFetcher
  # Thread-safe result/error accumulator shared by fetcher workers.
  FetchState = Struct.new(:mutex, :results, :errors, keyword_init: true) {
    def self.build
      new(mutex: Mutex.new, results: {}, errors: [])
    end

    def record_result(cache_key, versions)
      mutex.synchronize { results[cache_key] = versions }
    end

    def record_error(error)
      mutex.synchronize { errors << error }
    end
  }
  private_constant :FetchState

  def self.call(lookups, worker_limit:, persistent_cache: nil)
    new(lookups, worker_limit, persistent_cache:).call
  end

  def initialize(lookups, worker_limit, persistent_cache: nil)
    @lookups = lookups
    @worker_limit = worker_limit
    @persistent_cache = persistent_cache
    @state = FetchState.build
  end

  def call
    queue = build_queue
    workers(queue).each(&:value)
    raise_lookup_error unless @state.errors.empty?

    @state.results
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
    cache_key, repository_url, persistent_cache_key = queue.pop(true)
    @state.record_result(cache_key, versions_for(repository_url, persistent_cache_key))
  rescue GitOperations::LsRemoteError => error
    @state.record_error(error)
  end

  def versions_for(repository_url, persistent_cache_key)
    cached_versions = @persistent_cache&.read(persistent_cache_key)
    return cached_versions if cached_versions

    GitOperations.version_tags(repository_url)
      .tap { |versions| @persistent_cache&.write(persistent_cache_key, versions) }
  end

  def raise_lookup_error
    first_error = @state.errors.first
    message = @state.errors.map(&:message).uniq.join("\n")

    begin
      raise first_error
    rescue GitOperations::LsRemoteError
      error = GitOperations::LsRemoteError.new(message)
      error.set_backtrace(first_error.backtrace)
      raise error
    end
  end
end
