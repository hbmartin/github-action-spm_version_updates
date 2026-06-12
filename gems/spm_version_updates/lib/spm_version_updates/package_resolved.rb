# frozen_string_literal: true

require "json"
require_relative "git_operations"

# Parsing for `Package.resolved` files.
#
# Handles both the v1 format (pins nested under `"object"`) and the v2+ format
# (pins at the top level). This is shared between the Xcode-project source mode
# and the Swift package manifest source mode.
module PackageResolved
  # Raised when a `Package.resolved` file exists but is not valid JSON.
  class MalformedFileError < StandardError
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
    contents = load_contents(path)
    pins = contents["pins"] || contents.dig("object", "pins") || []
    pins.to_h { |pin|
      [
        GitOperations.trim_repo_url(pin["location"] || pin["repositoryURL"]),
        pin.dig("state", "version") || pin.dig("state", "revision"),
      ]
    }
  end

  def self.load_contents(path)
    JSON.load_file!(path)
  rescue JSON::ParserError => error
    raise(MalformedFileError.new(path, error.message))
  end

  private_class_method :load_contents
end
