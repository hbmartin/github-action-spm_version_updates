# frozen_string_literal: true

require "uri"

# Parses supported git remote URLs and renders host-specific links.
class RepositoryLink
  HOSTS = {
    "github.com" => {
      path_normalizer: ->(segments) { segments.first(2).join("/") if segments.size >= 2 },
      compare: ->(current, available) { "/compare/#{current}...#{available}" },
      release: ["Releases", "/releases"]
    },
    "gitlab.com" => {
      path_normalizer: ->(segments) { segments.join("/").sub(%r{/-/.*\z}, "").then { |path| path if path.count("/") >= 1 } },
      compare: ->(current, available) { "/-/compare/#{current}...#{available}" },
      release: ["Releases", "/-/releases"]
    },
    "bitbucket.org" => {
      path_normalizer: ->(segments) { segments.first(2).join("/") if segments.size >= 2 },
      compare: ->(current, available) { "/branches/compare/#{available}..#{current}" },
      release: ["Tags", "/downloads/?tab=tags"]
    }
  }.freeze
  SUPPORTED_HOSTS_PATTERN = Regexp.union(HOSTS.keys).source
  REMOTE_PATTERNS = [
    %r{\A(?:https?|git|ssh)://(?:[^@/\s]+@)?(?<host>#{SUPPORTED_HOSTS_PATTERN})(?::\d+)?/(?<path>.+)\z}i,
    %r{\A(?:[^@/\s]+@)?(?<host>#{SUPPORTED_HOSTS_PATTERN})[:/](?<path>.+)\z}i,
  ].freeze

  private_constant :HOSTS,
                   :SUPPORTED_HOSTS_PATTERN,
                   :REMOTE_PATTERNS

  def self.from(repository_url)
    link = new(repository_url)
    link if link.valid?
  end

  def initialize(repository_url)
    @value = repository_url.to_s.strip
    @host = nil
    @raw_path = nil
    @path = nil
    configure_remote(remote_match)
  end

  def valid?
    @host && @path
  end

  def compare_url(current, available)
    current_ref = URI.encode_www_form_component(current.to_s)
    available_ref = URI.encode_www_form_component(available.to_s)
    "#{base_url}#{link_builder.fetch(:compare).call(current_ref, available_ref)}"
  end

  def release_link
    label, path = link_builder.fetch(:release)
    "[#{label}](#{base_url}#{path})"
  end

  def markdown_links(updates, separator: "<br>")
    compare_links = updates.map.with_index(1) { |update, index|
      label = updates.size == 1 ? "Compare" : "Compare #{index}"
      "[#{label}](#{compare_url(update[:current], update[:available])})"
    }
    (compare_links + [release_link]).join(separator)
  end

  private

  def remote_match
    REMOTE_PATTERNS.each { |pattern|
      match = @value.match(pattern)
      return match if match
    }

    nil
  end

  def configure_remote(match)
    return unless match

    @host = match[:host].downcase
    @raw_path = match[:path]
    @path = normalized_path
  end

  def normalized_path
    link_builder.fetch(:path_normalizer).call(path_segments)
  end

  def path_segments
    @raw_path.to_s
      .split(/[?#]/, 2)
      .first
      .to_s
      .sub(%r{\A/+}, "")
      .sub(%r{/+\z}, "")
      .sub(/\.git\z/i, "")
      .split("/")
      .reject(&:empty?)
  end

  def base_url
    "https://#{@host}/#{@path}"
  end

  def link_builder
    HOSTS.fetch(@host)
  end
end
