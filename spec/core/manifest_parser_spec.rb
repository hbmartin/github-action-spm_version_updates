# frozen_string_literal: true

require "spm_version_updates/manifest_parser"
require "tempfile"

# These specs cover the Swift package manifest (Package.swift) parser used by
# the GitHub Action's manifest source mode. They do not require Swift, Danger,
# or an Xcode toolchain and can run on any Ruby runner.
RSpec.describe ManifestParser do
  let(:manifest_dir) { File.expand_path("../support/manifests", __dir__) }

  def parse(content, &on_skip)
    Tempfile.create(["Package", ".swift"]) do |file|
      file.write(content)
      file.flush
      return described_class.get_packages(file.path, &on_skip)
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
        "github.com/onevcat/Kingfisher" => declared(
          "https://github.com/onevcat/Kingfisher",
          { "kind" => "upToNextMajorVersion", "minimumVersion" => "7.0.0" }
        ),
        "github.com/apple/swift-argument-parser" => declared(
          "https://github.com/apple/swift-argument-parser.git",
          { "kind" => "exactVersion", "version" => "1.2.3" }
        ),
        "github.com/kean/Nuke" => declared(
          "https://github.com/kean/Nuke",
          { "kind" => "versionRange", "minimumVersion" => "12.0.0", "maximumVersion" => "13.0.0" }
        ),
        "github.com/hbmartin/analytics-swift" => declared("https://github.com/hbmartin/analytics-swift.git", { "kind" => "branch", "branch" => "main" }),
        "github.com/getsentry/sentry-cocoa" => declared(
          "https://github.com/getsentry/sentry-cocoa.git",
          { "kind" => "revision", "revision" => "14aa6e47b03b820fd2b338728637570b9e969994" }
        )
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

      expect(parse(content)).to eq(
        "github.com/a/multiline" => declared(
          "https://github.com/a/multiline",
          { "kind" => "upToNextMajorVersion", "minimumVersion" => "3.2.1" }
        )
      )
    end

    it "reports a skip for declarations with an unrecognized requirement", :aggregate_failures do
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/future", futureRequirement: "1.0.0"),
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT
      skips = []

      packages = parse(content) { |skip| skips << skip }

      expect(packages.keys).to eq(["github.com/a/active"])
      expect(skips).to eq([{ reason: "unrecognized_requirement", snippet: 'url: "https://github.com/a/future", futureRequirement: "1.0.0"' }])
    end

    it "reports a skip and stops scanning at unbalanced parentheses", :aggregate_failures do
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/before", from: "1.0.0"),
          .package(url: "https://github.com/a/broken", from: "1.0.0",
          .package(url: "https://github.com/a/after", from: "1.0.0"
      SWIFT
      skips = []

      packages = parse(content) { |skip| skips << skip }

      expect(packages.keys).to eq(["github.com/a/before"])
      expect(skips.size).to eq(1)
      expect(skips.first[:reason]).to eq("unbalanced_parentheses")
      expect(skips.first[:snippet]).to start_with('.package(url: "https://github.com/a/broken"')
    end

    it "does not report local path packages as skips", :aggregate_failures do
      skips = []

      packages = parse('.package(path: "../LocalOnly")') { |skip| skips << skip }

      expect(packages).to be_empty
      expect(skips).to be_empty
    end

    it "does not report skips for fully parseable manifests" do
      skips = []

      parse('.package(url: "https://github.com/a/b", from: "1.0.0")') { |skip| skips << skip }

      expect(skips).to be_empty
    end

    it "skips package declarations with interpolated URL strings and keeps neighboring packages", :aggregate_failures do
      skips = []
      content = <<~SWIFT
        let org = "a"
        dependencies: [
          .package(url: "https://github.com/a/before", from: "1.0.0"),
          .package(url: "https://github.com/\\(org)/dynamic", from: "1.0.0"),
          .package(url: "https://github.com/a/after", from: "1.0.0"),
        ]
      SWIFT

      packages = parse(content) { |skip| skips << skip }

      expect(packages.keys).to eq(["github.com/a/before", "github.com/a/after"])
      expect(skips.first[:reason]).to eq("unsupported_string_interpolation")
    end

    it "skips package declarations that use Swift raw strings", :aggregate_failures do
      skips = []
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/before", from: "1.0.0"),
          .package(url: #"https://github.com/a/raw"#, from: "1.0.0"),
          .package(url: "https://github.com/a/after", from: "1.0.0"),
        ]
      SWIFT

      packages = parse(content) { |skip| skips << skip }

      expect(packages.keys).to eq(["github.com/a/before", "github.com/a/after"])
      expect(skips.first[:reason]).to eq("unsupported_raw_string")
    end

    it "treats raw strings as opaque while stripping comments", :aggregate_failures do
      content = <<~SWIFT
        let text = #"this is not a // comment and not /* a block */"#
        dependencies: [
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT

      expect(parse(content).keys).to eq(["github.com/a/active"])
    end

    it "does not parse fake package declarations inside raw strings" do
      content = <<~SWIFT
        let text = #".package(url: "https://github.com/a/fake", from: "9.9.9")"#
        dependencies: [
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT

      expect(parse(content).keys).to eq(["github.com/a/active"])
    end

    it "keeps scanning after raw strings with escaped quotes and hashes" do
      content = <<~SWIFT
        let text = ##"quoted " text and a closing-looking "# fragment"##
        dependencies: [
          .package(url: "https://github.com/a/active", from: "1.0.0"),
        ]
      SWIFT

      expect(parse(content).keys).to eq(["github.com/a/active"])
    end

    it "reports unbalanced parentheses when a raw string reaches EOF inside a declaration", :aggregate_failures do
      skips = []
      content = <<~SWIFT
        dependencies: [
          .package(url: #"https://github.com/a/broken, from: "1.0.0")
      SWIFT

      expect(parse(content) { |skip| skips << skip }).to eq({})
      expect(skips.first[:reason]).to eq("unbalanced_parentheses")
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
