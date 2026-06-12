# frozen_string_literal: true

require "ipaddr"
require "uri"

# Extracts and normalizes hostnames from common git remote URL forms.
# @api private
module GitHostNormalizer
  HOST_PATTERN = /\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i
  BRACKETED_IPV6_PATTERN = /\A\[(?<address>[^\]]+)\](?::\d+)?\z/

  class << self
    def host(repo_url)
      url = repo_url.to_s.strip
      return nil if url.empty?

      parsed_host(url) || scp_like_host(url) || bare_host(url)
    end

    def parsed_host(url)
      normalize_host(URI.parse(url).host)
    rescue URI::InvalidURIError
      nil
    end

    def scp_like_host(url)
      match = url.match(%r{\A(?:[^@\s/]+@)?(?<host>[^:\s/]+):(?!/)[^:\s]+\z})
      match && normalize_host(match[:host])
    end

    def bare_host(url)
      return nil if url.start_with?("/", "./", "../")
      return nil if url.include?("://")

      normalize_host(url.split("/", 2).first)
    end

    def normalize_host(host)
      normalized = normalized_ipv6_host(host)
      return normalized if normalized

      normalized = host.to_s.sub(/:\d+\z/, "").downcase
      return normalized if normalized.match?(HOST_PATTERN)

      nil
    end

    def normalized_ipv6_host(host)
      raw = host.to_s.strip.downcase
      bracketed = raw.match(BRACKETED_IPV6_PATTERN)
      return normalize_ipv6_address(bracketed[:address]) if bracketed
      return normalize_ipv6_address(raw) if raw.count(":") >= 2

      nil
    end

    def normalize_ipv6_address(address)
      parsed = IPAddr.new(address)
      parsed.ipv6? ? parsed.to_s : nil
    rescue IPAddr::Error
      nil
    end
  end
end
