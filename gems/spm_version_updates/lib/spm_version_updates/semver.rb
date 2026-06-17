# frozen_string_literal: true

require "semverify"

# Namespace for the core gem's published constants (gem version and the
# {SpmVersionUpdates::Semver} value object).
module SpmVersionUpdates
  # SemVer value object used by both the GitHub Action and Danger plugin.
  class Semver
    include Comparable

    def self.normalize(value)
      value.to_s
        .sub(/\Av(?=\d)/, "")
        .sub(/\A(\d+)\.(\d+)(?=\z|[-+])/, '\1.\2.0')
    end

    def initialize(value)
      @version = Semverify::Semver.new(self.class.normalize(value))
    rescue Semverify::Error => error
      raise(ArgumentError, error.message)
    end

    def <=>(other)
      semver_class = self.class
      other_version = other.kind_of?(semver_class) ? other.version : semver_class.new(other).version
      version <=> other_version
    rescue ArgumentError
      nil
    end

    def major
      version.major.to_i
    end

    def minor
      version.minor.to_i
    end

    def patch
      version.patch.to_i
    end

    def pre
      version.pre_release.to_s.then { |value| value.empty? ? nil : value }
    end
    alias pre_release pre

    def to_s
      version.to_s
    end

    protected

    attr_reader :version
  end
end
