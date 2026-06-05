# frozen_string_literal: true

require "tmpdir"
require "json"
require_relative "../../lib/spm_checker"

# End-to-end specs for the manifest source mode of SpmChecker. Git access is
# stubbed so these run without network access.
RSpec.describe SpmChecker do
  def versions(*strings)
    strings.map { |string| Semantic::Version.new(string) }.sort.reverse
  end

  subject(:checker) { described_class.new }

  let(:manifests_dir) { File.expand_path("../support/manifests", __dir__) }
  let(:modules_manifest) { File.join(manifests_dir, "Modules", "Package.swift") }
  let(:build_tools_manifest) { File.join(manifests_dir, "BuildTools", "Package.swift") }

  before do
    allow(GitOperations).to receive(:version_tags) do |url|
      case url
      when /Kingfisher/ then versions("7.10.2", "7.5.0", "7.0.0")
      when /swift-argument-parser/ then versions("1.3.0", "1.2.3")
      when /Nuke/ then versions("13.0.0", "12.1.7", "12.0.0")
      when /SwiftGenPlugin/ then versions("6.7.0", "6.6.0")
      when /SwiftFormat/ then versions("0.53.0", "0.52.7", "0.52.0")
      else []
      end
    end
    allow(GitOperations).to receive(:branch_last_commit).and_return("1111111111111111111111111111111111111111")
  end

  describe "#check_manifests" do
    it "checks direct dependencies across multiple manifests and attributes the source" do
      checker.check_when_exact = true

      warnings = checker.check_manifests([modules_manifest, build_tools_manifest])

      expect(warnings).to eq(
        [
          "Newer version of onevcat/Kingfisher: 7.10.2\nSource: #{modules_manifest}",
          "Newer version of apple/swift-argument-parser: 1.3.0 (but this package is set to exact version 1.2.3)\nSource: #{modules_manifest}",
          "Newer version of kean/Nuke: 12.1.7\nSource: #{modules_manifest}",
          "Newer commit available for hbmartin/analytics-swift (main): 1111111111111111111111111111111111111111\nSource: #{modules_manifest}",
          "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0\nSource: #{build_tools_manifest}",
          "Newer version of nicklockwood/SwiftFormat: 0.52.7\nSource: #{build_tools_manifest}",
        ]
      )
    end

    it "does not check exact versions unless configured" do
      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).not_to include(a_string_matching(/swift-argument-parser/))
    end

    it "does not check branches when check_branches is disabled" do
      checker.check_branches = false

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).not_to include(a_string_matching(/analytics-swift/))
    end

    it "reports the latest tag for revision pins when check_revisions is enabled" do
      allow(GitOperations).to receive(:version_tags).with(/sentry-cocoa/).and_return(versions("8.20.0"))
      checker.check_revisions = true

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).to include(a_string_matching(/getsentry\/sentry-cocoa is pinned to a revision .* latest tagged version is 8.20.0/))
    end

    it "honors ignore_repos" do
      checker.ignore_repos = ["https://github.com/onevcat/Kingfisher"]

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).not_to include(a_string_matching(/Kingfisher/))
    end

    it "uses explicit resolved paths when provided" do
      resolved = File.join(manifests_dir, "Modules", "Package.resolved")

      warnings = checker.check_manifests([modules_manifest], [resolved])

      expect(warnings).to include(a_string_matching(/Newer version of onevcat\/Kingfisher: 7.10.2/))
    end

    it "raises a clear error when no resolved file can be found" do
      Dir.mktmpdir do |dir|
        manifest = File.join(dir, "Package.swift")
        File.write(manifest, '.package(url: "https://github.com/a/b", from: "1.0.0")')

        expect { checker.check_manifests([manifest]) }.to raise_error(ManifestParser::CouldNotFindResolvedFile)
      end
    end

    it "raises when any one manifest is missing its resolved file" do
      Dir.mktmpdir do |dir|
        without_resolved = File.join(dir, "Package.swift")
        File.write(without_resolved, '.package(url: "https://github.com/a/b", from: "1.0.0")')

        # The first manifest has a resolved file; the second does not.
        expect {
          checker.check_manifests([modules_manifest, without_resolved])
        }.to raise_error(ManifestParser::CouldNotFindResolvedFile, /#{Regexp.escape(without_resolved.sub(/Package\.swift\z/, 'Package.resolved'))}/)
      end
    end

    it "does not emit an empty warning when no available version satisfies the constraint" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Package.swift"), '.package(url: "https://github.com/a/b", from: "1.0.0")')
        File.write(File.join(dir, "Package.resolved"), {
          "pins" => [{ "location" => "https://github.com/a/b", "state" => { "version" => "1.0.0" } }],
          "version" => 2,
        }.to_json)
        # Only a newer *major* exists, which an upToNextMajor (`from:`) constraint excludes.
        allow(GitOperations).to receive(:version_tags).and_return(versions("2.0.0"))

        warnings = checker.check_manifests([File.join(dir, "Package.swift")])

        expect(warnings).to eq([])
      end
    end
  end
end
