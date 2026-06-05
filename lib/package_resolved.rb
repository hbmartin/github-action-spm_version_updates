# frozen_string_literal: true

require "json"
require_relative "git_operations"

# Parsing for `Package.resolved` files.
#
# Handles both the v1 format (pins nested under `"object"`) and the v2+ format
# (pins at the top level). This is shared between the Xcode-project source mode
# and the Swift package manifest source mode.
module PackageResolved
  # Extract the resolved version (or revision, when no version is pinned) for
  # every pin in a `Package.resolved` file.
  #
  # @param  [String] path The path to a `Package.resolved` file
  # @return [Hash<String, String>] normalized repository URL => version or revision
  def self.versions_from(path)
    contents = JSON.load_file!(path)
    pins = contents["pins"] || contents.dig("object", "pins") || []
    pins.to_h { |pin|
      [
        GitOperations.trim_repo_url(pin["location"] || pin["repositoryURL"]),
        pin.dig("state", "version") || pin.dig("state", "revision"),
      ]
    }
  end
end
