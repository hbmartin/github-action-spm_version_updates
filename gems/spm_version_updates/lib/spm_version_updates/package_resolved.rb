# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "git_operations"

# Parsing for `Package.resolved` files.
#
# Handles both the v1 format (pins nested under `"object"`) and the v2+ format
# (pins at the top level). This is shared between the Xcode-project source mode
# and the Swift package manifest source mode.
module PackageResolved
  # Raised when a `Package.resolved` file exists but is not valid JSON.
  class MalformedFileError < SpmVersionUpdates::ParseError
    attr_reader :path

    def initialize(path, parse_message)
      @path = path
      super("Malformed Package.resolved at #{path}: #{parse_message}")
    end
  end

  # Extract the resolved version (or revision, when no version is pinned) for
  # every pin in a `Package.resolved` file.
  #
  # @param  [String] path The path to a `Package.resolved` file
  # @raise [MalformedFileError] if the file is not valid JSON
  # @return [Hash<String, String>] normalized repository URL => version or revision
  def self.versions_from(path)
    pins_from(path).to_h { |pin| [pin["normalized_url"], pin["version"] || pin["revision"]] }
  end

  # Extract structured pins from a `Package.resolved` file.
  #
  # @param  [String] path The path to a `Package.resolved` file
  # @raise [MalformedFileError] if the file is not valid JSON
  # @return [Array<Hash>] pin records with normalized_url, repository_url,
  #   version, and revision
  def self.pins_from(path)
    contents = load_contents(path)
    pins = contents["pins"] || contents.dig("object", "pins") || []
    pins.map { |pin| pin_record(pin) }
  end

  def self.pin_record(pin)
    repository_url = pin["location"] || pin["repositoryURL"]
    state = pin["state"] || {}
    {
      "normalized_url" => GitOperations.trim_repo_url(repository_url),
      "repository_url" => repository_url,
      "version" => state["version"],
      "revision" => state["revision"]
    }
  end

  def self.load_contents(path)
    JSON.load_file!(path)
  rescue JSON::ParserError => error
    raise(MalformedFileError.new(path, error.message))
  end

  private_class_method :load_contents,
                       :pin_record
end
