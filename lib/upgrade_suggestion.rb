# frozen_string_literal: true

# Derives per-update upgrade guidance from a package's requirement kind and the
# available version: the SwiftPM identity, a ready-to-run `swift package update`
# command (manifest mode only), and the manifest requirement change needed when
# the new version is outside the declared constraint. Shared between the GitHub
# Action reporters and the Danger plugin.
module UpgradeSuggestion
  # SwiftPM's default package identity: the last path component of the
  # repository URL, lowercased (the normalized URL already has no `.git`).
  def self.identity(normalized_url)
    normalized_url.to_s.split("/").last.to_s.downcase
  end

  # @param package [SpmPackageContext]
  # @param available_version [#to_s] the version (or commit) being suggested
  # @param type [Symbol] :version, :above_maximum, :branch, or :revision
  # @return [Hash] package_identity / requirement_kind / suggested_command /
  #   suggested_requirement, with inapplicable entries nil
  def self.fields(package, available_version, type)
    {
      package_identity: identity(package.normalized_url),
      requirement_kind: package.kind,
      suggested_command: command(package),
      suggested_requirement: requirement_change(package, available_version.to_s, type)
    }
  end

  # `swift package update` only applies to Package.swift-managed dependencies
  # (never Xcode projects, where source is nil) and cannot move a revision pin.
  def self.command(package)
    return nil unless package.source
    return nil if package.kind == "revision"

    "swift package update #{identity(package.normalized_url)}"
  end

  # The Package.swift requirement text needed before `swift package update` can
  # reach the suggested version. In-range updates, branch pins, and revision
  # pins need no manifest change.
  def self.requirement_change(package, available, type)
    return above_maximum_change(package, available) if type == :above_maximum

    %(exact: "#{available}") if package.kind == "exactVersion"
  end

  def self.above_maximum_change(package, available)
    case package.kind
    when "exactVersion" then %(exact: "#{available}")
    when "upToNextMajorVersion" then %(from: "#{available}")
    when "upToNextMinorVersion" then %(.upToNextMinor(from: "#{available}"))
    when "versionRange" then range_change(package.requirement, available)
    end
  end
  private_class_method :above_maximum_change

  def self.range_change(requirement, available)
    major = available[/\A(\d+)/, 1]
    %("#{requirement['minimumVersion']}"..<"#{major.to_i + 1}.0.0") if major
  end
  private_class_method :range_change
end
