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

    it "queries git with the original scheme-bearing URL, not the normalized match key" do
      received = []
      allow(GitOperations).to receive(:version_tags) { |url| received << url; [] }

      checker.check_manifests([modules_manifest])

      # Regression: the normalized keys (github.com/...) are not valid git remotes.
      expect(received).to include("https://github.com/onevcat/Kingfisher", "https://github.com/kean/Nuke")
    end

    it "allows configured dependency hosts case-insensitively" do
      checker.allow_hosts = ["GitHub.com"]

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).to include("Newer version of onevcat/Kingfisher: 7.10.2\nSource: #{modules_manifest}")
    end

    it "fails before fetching version tags when a dependency host is not allowed" do
      checker.allow_hosts = ["github.com"]
      expect(GitOperations).not_to receive(:version_tags)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Package.swift"), '.package(url: "https://metadata.internal/a/b", from: "1.0.0")')
        File.write(File.join(dir, "Package.resolved"), {
          "pins" => [{ "location" => "https://metadata.internal/a/b", "state" => { "version" => "1.0.0" } }],
          "version" => 2,
        }.to_json)

        expect {
          checker.check_manifests([File.join(dir, "Package.swift")])
        }.to raise_error(SpmChecker::DisallowedRepositoryHost, /metadata\.internal.*allow-hosts/)
      end
    end

    it "fails before checking branch heads when a branch dependency host is not allowed" do
      checker.allow_hosts = ["github.com"]
      expect(GitOperations).not_to receive(:branch_last_commit)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Package.swift"), '.package(url: "git@metadata.internal:a/b.git", branch: "main")')
        File.write(File.join(dir, "Package.resolved"), {
          "pins" => [{ "location" => "git@metadata.internal:a/b.git", "state" => { "revision" => "abc123" } }],
          "version" => 2,
        }.to_json)

        expect {
          checker.check_manifests([File.join(dir, "Package.swift")])
        }.to raise_error(SpmChecker::DisallowedRepositoryHost, /metadata\.internal.*allow-hosts/)
      end
    end

    it "fetches version tags with a bounded worker pool and preserves warning order" do
      package_count = SpmChecker::VERSION_TAG_WORKER_COUNT + 4
      remote_packages = (1..package_count).each_with_object({}) { |index, packages|
        packages["github.com/acme/pkg#{index}"] = {
          "repository_url" => "https://github.com/acme/pkg#{index}",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" },
        }
      }
      resolved_versions = remote_packages.keys.to_h { |url| [url, "1.0.0"] }
      in_flight = 0
      max_in_flight = 0
      mutex = Mutex.new

      allow(GitOperations).to receive(:version_tags) do |_url|
        mutex.synchronize {
          in_flight += 1
          max_in_flight = [max_in_flight, in_flight].max
        }
        sleep 0.03
        versions("1.1.0", "1.0.0")
      ensure
        mutex.synchronize { in_flight -= 1 }
      end

      checker.send(:check_packages, remote_packages, resolved_versions)

      expect(max_in_flight).to be_between(2, SpmChecker::VERSION_TAG_WORKER_COUNT).inclusive
      expect(checker.instance_variable_get(:@warnings)).to eq(
        (1..package_count).map { |index| "Newer version of acme/pkg#{index}: 1.1.0" }
      )
    end

    it "memoizes version tags across manifests in one check" do
      calls = []
      mutex = Mutex.new
      allow(GitOperations).to receive(:version_tags) do |url|
        mutex.synchronize { calls << url }
        versions("1.1.0", "1.0.0")
      end

      Dir.mktmpdir do |dir|
        manifests = %w[App Tools].map { |name|
          manifest_dir = File.join(dir, name)
          Dir.mkdir(manifest_dir)
          manifest = File.join(manifest_dir, "Package.swift")
          File.write(manifest, '.package(url: "https://github.com/acme/shared", from: "1.0.0")')
          File.write(File.join(manifest_dir, "Package.resolved"), {
            "pins" => [{ "location" => "https://github.com/acme/shared", "state" => { "version" => "1.0.0" } }],
            "version" => 2,
          }.to_json)
          manifest
        }

        warnings = checker.check_manifests(manifests)

        expect(calls).to eq(["https://github.com/acme/shared"])
        expect(warnings).to eq(
          [
            "Newer version of acme/shared: 1.1.0\nSource: #{manifests[0]}",
            "Newer version of acme/shared: 1.1.0\nSource: #{manifests[1]}",
          ]
        )
      end
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

    it "exposes structured warning details for grouped PR comments" do
      warnings = checker.check_manifests([modules_manifest])

      detail = checker.warning_details.find { |warning| warning[:package] == "onevcat/Kingfisher" }

      expect(warnings).to include("Newer version of onevcat/Kingfisher: 7.10.2\nSource: #{modules_manifest}")
      expect(detail).to include(
        type: "version",
        package: "onevcat/Kingfisher",
        normalized_url: "github.com/onevcat/Kingfisher",
        repository_url: "https://github.com/onevcat/Kingfisher",
        current_version: "7.0.0",
        available_version: "7.10.2",
        source: modules_manifest
      )
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

    it "does not match a different major version for up-to-next-minor constraints" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Package.swift"), '.package(url: "https://github.com/a/b", .upToNextMinor(from: "1.5.0"))')
        File.write(File.join(dir, "Package.resolved"), {
          "pins" => [{ "location" => "https://github.com/a/b", "state" => { "version" => "1.5.0" } }],
          "version" => 2,
        }.to_json)
        # 2.5.0 shares the minor component but a different major; it must not match.
        allow(GitOperations).to receive(:version_tags).and_return(versions("2.5.0", "1.5.3", "1.5.0"))

        warnings = checker.check_manifests([File.join(dir, "Package.swift")])

        expect(warnings).to eq(["Newer version of a/b: 1.5.3\nSource: #{File.join(dir, 'Package.swift')}"])
      end
    end

    it "does not report a pre-release as the newest version in a range when pre-releases are filtered" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Package.swift"), '.package(url: "https://github.com/a/b", "1.0.0"..<"3.0.0")')
        File.write(File.join(dir, "Package.resolved"), {
          "pins" => [{ "location" => "https://github.com/a/b", "state" => { "version" => "1.0.0" } }],
          "version" => 2,
        }.to_json)
        # 3.0.0-beta.1 is the absolute newest but a pre-release; report 2.0.0.
        allow(GitOperations).to receive(:version_tags).and_return(versions("3.0.0-beta.1", "2.0.0", "1.0.0"))

        warnings = checker.check_manifests([File.join(dir, "Package.swift")])

        expect(warnings).to eq(["Newer version of a/b: 2.0.0\nSource: #{File.join(dir, 'Package.swift')}"])
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

    it "skips malformed package entries with nil requirements" do
      remote_packages = {
        "github.com/a/b" => { "repository_url" => "https://github.com/a/b", "requirement" => nil },
      }

      expect(GitOperations).not_to receive(:version_tags)

      checker.send(:check_packages, remote_packages, "github.com/a/b" => "1.0.0")

      expect(checker.instance_variable_get(:@warnings)).to eq([])
    end
  end
end
