# frozen_string_literal: true

# Category base classes for every error raised by spm_version_updates, so
# callers can rescue by failure kind instead of enumerating each concrete
# class. The concrete classes (e.g. ManifestParser::CouldNotFindManifest)
# keep their existing names and namespaces; only their superclasses point
# here.
module SpmVersionUpdates
  # Base class for all errors raised by spm_version_updates.
  class Error < StandardError; end

  # Invalid user-supplied configuration or inputs. Inherits ArgumentError (not
  # Error) so existing callers that rescue ArgumentError keep working; rescue
  # it alongside Error when catching everything this gem raises.
  class ConfigurationError < ArgumentError; end

  # A required file (manifest, Package.resolved) could not be found.
  class FileNotFoundError < Error; end

  # A file exists but could not be parsed.
  class ParseError < Error; end

  # git or network lookup failures.
  class NetworkError < Error; end

  # Policy violations, e.g. a repository host blocked by allow-hosts.
  class PolicyError < Error; end
end
