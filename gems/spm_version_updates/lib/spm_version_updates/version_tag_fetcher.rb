# frozen_string_literal: true

require_relative "git_operations"

# Fetches git tag versions concurrently for cache-key/repository URL lookup pairs.
# @api private
class VersionTagFetcher
  # Thread-safe result/error accumulator shared by fetcher workers.
  FetchState = Struct.new(:mutex, :results, :errors, keyword_init: true) {
    def self.build
      new(mutex: Mutex.new, results: {}, errors: {})
    end

    def record_result(cache_key, versions)
      mutex.synchronize { results[cache_key] = versions }
    end

    def record_error(cache_key, error)
      mutex.synchronize { errors[cache_key] = error }
    end
  }
  private_constant :FetchState

  # Re-raises worker lookup failures as one combined git lookup error.
  LookupErrors = Struct.new(:errors) {
    def raise_error
      first_error = errors.first

      raise(combined_error(first_error), cause: first_error) if first_error.kind_of?(GitOperations::LsRemoteError)

      raise(first_error)
    end

    private

    def combined_error(first_error)
      GitOperations::LsRemoteError.new(message).tap { |error| error.set_backtrace(first_error.backtrace) }
    end

    def message
      errors.map(&:message).uniq.join("\n")
    end
  }
  private_constant :LookupErrors

  # Fetch all lookups, returning `[results, errors]`, both keyed by cache key.
  #
  # With `raise_on_error: true` (the default) any lookup failure is re-raised as
  # one combined error after all workers finish; `errors` is then always empty.
  # With `raise_on_error: false` failed lookups are returned in `errors` so the
  # caller can degrade gracefully per package.
  def self.call(lookups, worker_limit:, persistent_cache: nil, raise_on_error: true)
    new(lookups, worker_limit, persistent_cache:, raise_on_error:).call
  end

  def initialize(lookups, worker_limit, persistent_cache: nil, raise_on_error: true)
    @lookups = lookups
    @worker_limit = worker_limit
    @persistent_cache = persistent_cache
    @raise_on_error = raise_on_error
    @state = FetchState.build
  end

  def call
    queue = build_queue
    workers(queue).each(&:value)
    errors = @state.errors
    raise_lookup_error if @raise_on_error && !errors.empty?

    [@state.results, errors]
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
    @state.record_error(cache_key, error)
  end

  def versions_for(repository_url, persistent_cache_key)
    cached_versions = @persistent_cache&.read(persistent_cache_key)
    return cached_versions if cached_versions

    GitOperations.version_tags(repository_url)
      .tap { |versions| @persistent_cache&.write(persistent_cache_key, versions) }
  end

  def raise_lookup_error
    LookupErrors.new(@state.errors.values).raise_error
  end
end
