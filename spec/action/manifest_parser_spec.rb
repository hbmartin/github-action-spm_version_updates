# frozen_string_literal: true

require "tempfile"
require_relative "../../lib/manifest_parser"

# These specs cover the Swift package manifest (Package.swift) parser used by
# the GitHub Action's manifest source mode. They do not require Swift, Danger,
# or an Xcode toolchain and can run on any Ruby runner.
RSpec.describe ManifestParser do
  let(:manifest_dir) { File.expand_path("../support/manifests", __dir__) }

  def parse(content)
    Tempfile.create(["Package", ".swift"]) do |file|
      file.write(content)
      file.flush
      return described_class.get_packages(file.path)
    end
  end

  # Mirror the shape returned by ManifestParser.get_packages: the original
  # (scheme-bearing) repository URL kept alongside its parsed requirement.
  def declared(repository_url, requirement)
    { "repository_url" => repository_url, "requirement" => requirement }
  end

  describe ".get_packages" do
    it "parses the common declaration forms from a real manifest" do
      packages = described_class.get_packages(File.join(manifest_dir, "Modules", "Package.swift"))

      expect(packages).to eq(
        "github.com/onevcat/Kingfisher" => declared("https://github.com/onevcat/Kingfisher", { "kind" => "upToNextMajorVersion", "minimumVersion" => "7.0.0" }),
        "github.com/apple/swift-argument-parser" => declared("https://github.com/apple/swift-argument-parser.git", { "kind" => "exactVersion", "version" => "1.2.3" }),
        "github.com/kean/Nuke" => declared("https://github.com/kean/Nuke", { "kind" => "versionRange", "minimumVersion" => "12.0.0", "maximumVersion" => "13.0.0" }),
        "github.com/hbmartin/analytics-swift" => declared("https://github.com/hbmartin/analytics-swift.git", { "kind" => "branch", "branch" => "main" }),
        "github.com/getsentry/sentry-cocoa" => declared("https://github.com/getsentry/sentry-cocoa.git", { "kind" => "revision", "revision" => "14aa6e47b03b820fd2b338728637570b9e969994" })
      )
    end

    it "skips local path packages" do
      packages = parse('let p = [.package(path: "../LocalOnly"), .package(url: "https://github.com/a/b", from: "1.0.0")]')

      expect(packages).to eq("github.com/a/b" => declared("https://github.com/a/b", { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }))
    end

    it "ignores packages inside line and block comments" do
      content = <<~SWIFT
        dependencies: [
          // .package(url: "https://github.com/a/linecommented", from: "9.9.9"),
          /* .package(url: "https://github.com/a/blockcommented", from: "8.8.8") */
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT

      expect(parse(content).keys).to eq(["github.com/a/active"])
    end

    it "does not treat // inside a URL as a comment" do
      packages = parse('.package(url: "https://github.com/a/b", from: "1.0.0")')

      expect(packages).to eq("github.com/a/b" => declared("https://github.com/a/b", { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }))
    end

    it "supports the method-style requirement forms" do
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/exact", .exact("1.0.0")),
          .package(url: "https://github.com/a/branch", .branch("dev")),
          .package(url: "https://github.com/a/revision", .revision("deadbeef")),
          .package(url: "https://github.com/a/major", .upToNextMajor(from: "2.0.0")),
          .package(url: "https://github.com/a/minor", .upToNextMinor(from: "3.0.0")),
        ]
      SWIFT

      expect(parse(content)).to eq(
        "github.com/a/exact" => declared("https://github.com/a/exact", { "kind" => "exactVersion", "version" => "1.0.0" }),
        "github.com/a/branch" => declared("https://github.com/a/branch", { "kind" => "branch", "branch" => "dev" }),
        "github.com/a/revision" => declared("https://github.com/a/revision", { "kind" => "revision", "revision" => "deadbeef" }),
        "github.com/a/major" => declared("https://github.com/a/major", { "kind" => "upToNextMajorVersion", "minimumVersion" => "2.0.0" }),
        "github.com/a/minor" => declared("https://github.com/a/minor", { "kind" => "upToNextMinorVersion", "minimumVersion" => "3.0.0" })
      )
    end

    it "supports half-open and closed version ranges" do
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/halfopen", "1.0.0"..<"2.0.0"),
          .package(url: "https://github.com/a/closed", "1.0.0"..."2.0.0"),
        ]
      SWIFT

      # SwiftPM normalizes a closed range `a...b` to the half-open range
      # `a ..< (b with patch + 1)`, so the inclusive upper bound 2.0.0 becomes
      # an exclusive maximum of 2.0.1.
      expect(parse(content)).to eq(
        "github.com/a/halfopen" => declared("https://github.com/a/halfopen", { "kind" => "versionRange", "minimumVersion" => "1.0.0", "maximumVersion" => "2.0.0" }),
        "github.com/a/closed" => declared("https://github.com/a/closed", { "kind" => "versionRange", "minimumVersion" => "1.0.0", "maximumVersion" => "2.0.1" })
      )
    end

    it "drops the pre-release suffix when normalizing a closed range upper bound" do
      content = '.package(url: "https://github.com/a/b", "1.0.0"..."2.0.0-beta")'

      # Carrying the suffix (e.g. 2.0.1-beta) would over-expand the range; SwiftPM
      # derives the bound as Version(major, minor, patch + 1) without the suffix.
      expect(parse(content)).to eq(
        "github.com/a/b" => declared("https://github.com/a/b", { "kind" => "versionRange", "minimumVersion" => "1.0.0", "maximumVersion" => "2.0.1" })
      )
    end

    it "ignores packages inside nested block comments" do
      content = <<~SWIFT
        dependencies: [
          /* outer /* .package(url: "https://github.com/a/nested", from: "9.9.9") */ still commented */
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT

      expect(parse(content).keys).to eq(["github.com/a/active"])
    end

    it "parses requirements that span multiple lines" do
      content = <<~SWIFT
        .package(
          url: "https://github.com/a/multiline",
          from: "3.2.1"
        )
      SWIFT

      expect(parse(content)).to eq("github.com/a/multiline" => declared("https://github.com/a/multiline", { "kind" => "upToNextMajorVersion", "minimumVersion" => "3.2.1" }))
    end

    it "raises when the manifest path is blank" do
      expect { described_class.get_packages("") }
        .to raise_error(ManifestParser::ManifestPathMustBeSet)
    end

    it "raises when the manifest file is missing" do
      expect { described_class.get_packages("/no/such/Package.swift") }
        .to raise_error(ManifestParser::CouldNotFindManifest)
    end
  end

  describe ".default_resolved_path" do
    it "points at a Package.resolved next to the manifest" do
      expect(described_class.default_resolved_path("Modules/Package.swift")).to eq("Modules/Package.resolved")
    end
  end

  describe ".get_resolved_versions" do
    it "reads pinned versions from a Package.resolved" do
      resolved = described_class.get_resolved_versions(File.join(manifest_dir, "BuildTools", "Package.resolved"))

      expect(resolved).to eq(
        "github.com/SwiftGen/SwiftGenPlugin" => "6.6.0",
        "github.com/nicklockwood/SwiftFormat" => "0.52.0"
      )
    end
  end
end
