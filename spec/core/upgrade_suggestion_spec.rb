# frozen_string_literal: true

require "spm_version_updates/spm_package_context"
require "spm_version_updates/upgrade_suggestion"

RSpec.describe(UpgradeSuggestion) {
  def package(kind:, source: "Modules/Package.swift", requirement: {}, normalized_url: "github.com/onevcat/Kingfisher")
    SpmPackageContext.new(
      kind:,
      name: "onevcat/Kingfisher",
      normalized_url:,
      repository_url: "https://#{normalized_url}",
      requirement: { "kind" => kind }.merge(requirement),
      resolved_version: "7.0.0",
      source:
    )
  end

  describe(".identity") {
    it("uses the lowercased last path segment", :aggregate_failures) {
      expect(described_class.identity("github.com/onevcat/Kingfisher")).to(eq("kingfisher"))
      expect(described_class.identity("gitlab.com/group/subgroup/Project")).to(eq("project"))
    }

    it("returns an empty string for blank input") {
      expect(described_class.identity(nil)).to(eq(""))
    }
  }

  describe(".fields") {
    it("suggests a command but no manifest change for in-range version updates") {
      fields = described_class.fields(package(kind: "upToNextMajorVersion"), "7.10.2", :version)

      expect(fields).to(eq(
                          package_identity: "kingfisher",
                          requirement_kind: "upToNextMajorVersion",
                          suggested_command: "swift package update kingfisher",
                          suggested_requirement: nil
                        ))
    }

    it("suggests a from: bump for above-maximum updates on upToNextMajorVersion") {
      fields = described_class.fields(package(kind: "upToNextMajorVersion"), "8.0.0", :above_maximum)

      expect(fields[:suggested_requirement]).to(eq('from: "8.0.0"'))
    }

    it("suggests .upToNextMinor for above-maximum updates on upToNextMinorVersion") {
      fields = described_class.fields(package(kind: "upToNextMinorVersion"), "7.1.0", :above_maximum)

      expect(fields[:suggested_requirement]).to(eq('.upToNextMinor(from: "7.1.0")'))
    }

    it("suggests a widened range for above-maximum updates on versionRange") {
      fields = described_class.fields(
        package(kind: "versionRange", requirement: { "minimumVersion" => "7.0.0", "maximumVersion" => "8.0.0" }),
        "8.1.0",
        :above_maximum
      )

      expect(fields[:suggested_requirement]).to(eq('"7.0.0"..<"9.0.0"'))
    }

    it("omits a range suggestion when the available version is not semver-like") {
      fields = described_class.fields(
        package(kind: "versionRange", requirement: { "minimumVersion" => "7.0.0" }),
        "not-a-version",
        :above_maximum
      )

      expect(fields[:suggested_requirement]).to(be_nil)
    }

    it("always suggests the exact requirement change for exactVersion updates", :aggregate_failures) {
      fields = described_class.fields(package(kind: "exactVersion"), "7.10.2", :version)

      expect(fields[:suggested_requirement]).to(eq('exact: "7.10.2"'))
      expect(fields[:suggested_command]).to(eq("swift package update kingfisher"))
    }

    it("suggests only a command for branch pins", :aggregate_failures) {
      fields = described_class.fields(package(kind: "branch", requirement: { "branch" => "main" }), "abc123", :branch)

      expect(fields[:suggested_command]).to(eq("swift package update kingfisher"))
      expect(fields[:suggested_requirement]).to(be_nil)
    }

    it("suggests nothing actionable for revision pins", :aggregate_failures) {
      fields = described_class.fields(package(kind: "revision"), "7.10.2", :revision)

      expect(fields[:suggested_command]).to(be_nil)
      expect(fields[:suggested_requirement]).to(be_nil)
    }

    it("never suggests swift package update in Xcode mode", :aggregate_failures) {
      fields = described_class.fields(package(kind: "upToNextMajorVersion", source: nil), "7.10.2", :version)

      expect(fields[:suggested_command]).to(be_nil)
      expect(fields[:package_identity]).to(eq("kingfisher"))
    }
  }
}
