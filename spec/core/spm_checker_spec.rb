# frozen_string_literal: true

require "json"
require "spm_version_updates/spm_checker"
require "timeout"
require "tmpdir"

# Writes temporary Swift package manifests and resolved files for specs.
class ManifestPackageFixture
  DEFAULT_URL = "https://github.com/a/b"
  BRANCH_URL = "git@metadata.internal:a/b.git"
  REVISION_URL = "https://metadata.internal/a/b"

  class << self
    def write(dir, options)
      manifest = File.join(dir, "Package.swift")
      url = options.fetch(:url)
      File.write(manifest, ".package(url: \"#{url}\", #{options.fetch(:requirement)})")
      File.write(
        File.join(dir, "Package.resolved"),
        {
          "pins" => [{ "location" => url, "state" => options.fetch(:resolved_state) }],
          "version" => 2
        }.to_json
      )
      manifest
    end

    def write_version(dir, options = {})
      write(
        dir,
        url: options.fetch(:url, DEFAULT_URL),
        requirement: options.fetch(:requirement, 'from: "1.0.0"'),
        resolved_state: { "version" => options.fetch(:version, "1.0.0") }
      )
    end

    def write_branch(dir)
      write(dir, url: BRANCH_URL, requirement: 'branch: "main"', resolved_state: { "revision" => "abc123" })
    end

    def write_revision(dir)
      write(dir, url: REVISION_URL, requirement: 'revision: "abc123"', resolved_state: { "revision" => "abc123" })
    end
  end
end

# End-to-end specs for the manifest source mode of SpmChecker. Git access is
# stubbed so these run without network access.
RSpec.describe SpmChecker do
  def versions(*strings)
    strings.map { |string| SpmVersionUpdates::Semver.new(string) }
      .sort.reverse
  end

  def stub_default_versions
    allow(GitOperations).to receive(:version_tags)
      .with("https://github.com/a/b")
      .and_return(versions("2.0.0", "1.1.0", "1.0.0"))
  end

  def apply_repository_rule(rule)
    checker.repository_update_rules = RepositoryUpdateRules.from_hash("repositories" => [rule])
  end

  subject(:checker) { described_class.new }

  let(:manifests_dir) { File.expand_path("../support/manifests", __dir__) }
  let(:modules_manifest) { File.join(manifests_dir, "Modules", "Package.swift") }
  let(:build_tools_manifest) { File.join(manifests_dir, "BuildTools", "Package.swift") }
  let(:persistent_cache_key) {
    VersionTagsPersistentCache.cache_key("github.com/acme/shared", "https://github.com/acme/shared")
  }
  let(:cache_record_writer) {
    lambda { |dir, tags:, repository_url: "https://github.com/acme/shared", fetched_at: Time.now.utc.iso8601|
      cache_key = VersionTagsPersistentCache.cache_key("github.com/acme/shared", repository_url)
      File.write(
        File.join(dir, "#{cache_key}.json"),
        JSON.pretty_generate(
          {
            "schema_version" => VersionTagsPersistentCache::SCHEMA_VERSION,
            "fetched_at" => fetched_at,
            "tags" => tags
          }
        )
      )
    }
  }

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
      allow(GitOperations).to receive(:version_tags) { |url|
                                received << url
                                []
                              }

      checker.check_manifests([modules_manifest])

      # Regression: the normalized keys (github.com/...) are not valid git remotes.
      expect(received).to include("https://github.com/onevcat/Kingfisher", "https://github.com/kean/Nuke")
    end

    it "allows configured dependency hosts case-insensitively" do
      checker.allow_hosts = ["GitHub.com"]

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).to include("Newer version of onevcat/Kingfisher: 7.10.2\nSource: #{modules_manifest}")
    end

    it "strips ports from configured dependency hosts in fallback normalization" do
      allow(GitOperations).to receive(:host).with("GitHub.com:8443").and_return(nil)
      checker.allow_hosts = ["GitHub.com:8443"]

      checker.send(:normalize_allow_hosts)

      expect(checker.allow_hosts).to eq(["github.com"])
    end

    it "warns about malformed configured dependency hosts", :aggregate_failures do
      checker.allow_hosts = ["https//github.com", "not a host!", "github.com"]

      expect {
        checker.send(:normalize_allow_hosts)
      }.to output(
        a_string_including(
          'allow-hosts entry "https//github.com"',
          'allow-hosts entry "not a host!"'
        )
      ).to_stderr
      expect(checker.allow_hosts).to eq(["github.com"])
    end

    it "fails closed when every configured dependency host is malformed", :aggregate_failures do
      checker.allow_hosts = ["https//github.com", "not a host!"]

      expect {
        expect {
          checker.send(:normalize_allow_hosts)
        }.to raise_error(ArgumentError, /allow-hosts was configured/)
      }.to output(
        a_string_including(
          'allow-hosts entry "https//github.com"',
          'allow-hosts entry "not a host!"'
        )
      ).to_stderr
    end

    it "fails before fetching version tags when a dependency host is not allowed", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir, url: "https://metadata.internal/a/b")

        expect {
          checker.check_manifests([manifest])
        }.to raise_error(SpmChecker::DisallowedRepositoryHost, /metadata\.internal.*allow-hosts/)
      end

      expect(GitOperations).not_to have_received(:version_tags)
    end

    it "rejects parser-differential URLs whose real host is not allowed", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      Dir.mktmpdir do |dir|
        url = "https://github.com@evil.com/a/b"
        manifest = ManifestPackageFixture.write_version(dir, url:)

        expect {
          checker.check_manifests([manifest])
        }.to raise_error(SpmChecker::DisallowedRepositoryHost, /evil\.com.*allow-hosts/)
      end

      expect(GitOperations).not_to have_received(:version_tags)
    end

    it "rejects local and ext transports before fetching when allow-hosts is configured", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      ["file:///tmp/private-repo", "ext::sh -c touch /tmp/pwned"].each do |url|
        Dir.mktmpdir do |dir|
          manifest = ManifestPackageFixture.write_version(dir, url:)

          expect {
            checker.check_manifests([manifest])
          }.to raise_error(SpmChecker::DisallowedRepositoryHost, /unknown host.*allow-hosts/)
        end
      end

      expect(GitOperations).not_to have_received(:version_tags)
    end

    it "fails before checking branch heads when a branch dependency host is not allowed", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_branch(dir)

        expect {
          checker.check_manifests([manifest])
        }.to raise_error(SpmChecker::DisallowedRepositoryHost, /metadata\.internal.*allow-hosts/)
      end

      expect(GitOperations).not_to have_received(:branch_last_commit)
    end

    it "does not block off-list exact dependencies when exact-version checks are disabled", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir, url: "https://metadata.internal/a/b", requirement: 'exact: "1.0.0"')

        expect(checker.check_manifests([manifest])).to eq([])
      end

      expect(GitOperations).not_to have_received(:version_tags)
    end

    it "does not block off-list branch dependencies when branch checks are disabled", :aggregate_failures do
      checker.allow_hosts = ["github.com"]
      checker.check_branches = false

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_branch(dir)

        expect(checker.check_manifests([manifest])).to eq([])
      end

      expect(GitOperations).not_to have_received(:branch_last_commit)
    end

    it "does not block off-list revision dependencies when revision checks are disabled", :aggregate_failures do
      checker.allow_hosts = ["github.com"]

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_revision(dir)

        expect(checker.check_manifests([manifest])).to eq([])
      end

      expect(GitOperations).not_to have_received(:version_tags)
    end

    it "fetches version tags with a bounded worker pool and preserves warning order", :aggregate_failures do
      package_count = SpmChecker::VERSION_TAG_WORKER_COUNT + 4
      remote_packages = (1..package_count).each_with_object({}) { |index, packages|
        packages["github.com/acme/pkg#{index}"] = {
          "repository_url" => "https://github.com/acme/pkg#{index}",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
        }
      }
      resolved_versions = remote_packages.keys.to_h { |url| [url, "1.0.0"] }
      in_flight = 0
      max_in_flight = 0
      mutex = Mutex.new
      release = Queue.new
      started = Queue.new

      allow(GitOperations).to receive(:version_tags) do |_url|
        mutex.synchronize {
          in_flight += 1
          max_in_flight = [max_in_flight, in_flight].max
        }
        started << true
        release.pop
        versions("1.1.0", "1.0.0")
      ensure
        mutex.synchronize { in_flight -= 1 }
      end

      checker_thread = Thread.new { checker.send(:check_packages, remote_packages, resolved_versions) }

      begin
        Timeout.timeout(2) {
          SpmChecker::VERSION_TAG_WORKER_COUNT.times { started.pop }
        }
        expect(max_in_flight).to eq(SpmChecker::VERSION_TAG_WORKER_COUNT)
      ensure
        package_count.times { release << true }
        checker_thread.value
      end

      expect(checker.instance_variable_get(:@warnings)).to eq(
        (1..package_count).map { |index| "Newer version of acme/pkg#{index}: 1.1.0" }
      )
    end

    it "memoizes version tags across manifests in one check", :aggregate_failures do
      calls = []
      mutex = Mutex.new
      allow(GitOperations).to receive(:version_tags) do |url|
        mutex.synchronize { calls << url }
        versions("1.1.0", "1.0.0")
      end

      Dir.mktmpdir do |dir|
        manifests = %w(App Tools).map { |name|
          manifest_dir = File.join(dir, name)
          Dir.mkdir(manifest_dir)
          manifest = File.join(manifest_dir, "Package.swift")
          File.write(manifest, '.package(url: "https://github.com/acme/shared", from: "1.0.0")')
          File.write(File.join(manifest_dir, "Package.resolved"),
                     {
                       "pins" => [{ "location" => "https://github.com/acme/shared", "state" => { "version" => "1.0.0" } }],
                       "version" => 2
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

    it "scopes memoized version tags by repository URL", :aggregate_failures do
      calls = []
      allow(GitOperations).to receive(:version_tags) do |url|
        calls << url
        url.start_with?("https://") ? [] : versions("1.1.0", "1.0.0")
      end
      resolved_versions = { "github.com/acme/shared" => "1.0.0" }
      https_packages = {
        "github.com/acme/shared" => {
          "repository_url" => "https://github.com/acme/shared",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
        }
      }
      git_packages = {
        "github.com/acme/shared" => {
          "repository_url" => "git://github.com/acme/shared",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
        }
      }

      checker.send(:check_packages, https_packages, resolved_versions, "App/Package.swift")
      checker.send(:check_packages, git_packages, resolved_versions, "Tools/Package.swift")

      expect(calls).to eq(["https://github.com/acme/shared", "git://github.com/acme/shared"])
      expect(checker.instance_variable_get(:@warnings)).to eq(
        ["Newer version of acme/shared: 1.1.0\nSource: Tools/Package.swift"]
      )
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

      expect(warnings).to include(a_string_matching(%r{getsentry/sentry-cocoa is pinned to a revision .* latest tagged version is 8.20.0}))
    end

    it "honors ignore_repos", :aggregate_failures do
      checker.ignore_repos = ["https://github.com/onevcat/Kingfisher"]

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).not_to include(a_string_matching(/Kingfisher/))
      expect(GitOperations).not_to have_received(:version_tags).with("https://github.com/onevcat/Kingfisher")
    end

    it "suppresses manifest semantic warnings below an ignore-until version", :aggregate_failures do
      checker.repository_update_rules = RepositoryUpdateRules.from_hash(
        "repositories" => [
          { "url" => "ssh://github.com/onevcat/Kingfisher.git", "ignore-until" => "8.0.0" },
        ]
      )

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).not_to include(a_string_matching(/Kingfisher/))
      expect(GitOperations).to have_received(:version_tags).with("https://github.com/onevcat/Kingfisher")
    end

    it "reports semantic warnings when the available version reaches ignore-until" do
      checker.repository_update_rules = RepositoryUpdateRules.from_hash(
        "repositories" => [
          { "url" => "https://github.com/onevcat/Kingfisher", "ignore-until" => "7.10.2" },
        ]
      )

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).to include("Newer version of onevcat/Kingfisher: 7.10.2\nSource: #{modules_manifest}")
    end

    it "applies ignore-until to above-maximum semantic reports" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        stub_default_versions
        checker.report_above_maximum = true
        apply_repository_rule("url" => "https://github.com/a/b", "ignore-until" => "2.0.0")

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq(
          ["Newest version of a/b: 2.0.0 (but this package is configured up to the next major version)\nSource: #{manifest}"]
        )
      end
    end

    it "allows only patch and minor reports when allowed-updates is minor" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        stub_default_versions
        checker.report_above_maximum = true
        apply_repository_rule("url" => "https://github.com/a/b", "allowed-updates" => "minor")

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq(["Newer version of a/b: 1.1.0\nSource: #{manifest}"])
      end
    end

    it "combines ignore-until and allowed-updates suppression" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        stub_default_versions
        checker.report_above_maximum = true
        apply_repository_rule("url" => "https://github.com/a/b", "ignore-until" => "2.0.0", "allowed-updates" => "minor")

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq([])
      end
    end

    it "does not apply repo rules to branch warnings" do
      checker.repository_update_rules = RepositoryUpdateRules.from_hash(
        "repositories" => [
          { "url" => "https://github.com/hbmartin/analytics-swift", "allowed-updates" => "patch" },
        ]
      )

      warnings = checker.check_manifests([modules_manifest])

      expect(warnings).to include(
        "Newer commit available for hbmartin/analytics-swift (main): 1111111111111111111111111111111111111111\nSource: #{modules_manifest}"
      )
    end

    it "uses explicit resolved paths when provided" do
      resolved = File.join(manifests_dir, "Modules", "Package.resolved")

      warnings = checker.check_manifests([modules_manifest], [resolved])

      expect(warnings).to include(a_string_matching(%r{Newer version of onevcat/Kingfisher: 7.10.2}))
    end

    it "exposes structured warning details for grouped PR comments", :aggregate_failures do
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

        expect { checker.check_manifests([manifest]) }
          .to raise_error(ManifestParser::CouldNotFindResolvedFile)
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
        manifest = ManifestPackageFixture.write_version(dir, requirement: '.upToNextMinor(from: "1.5.0")', version: "1.5.0")
        # 2.5.0 shares the minor component but a different major; it must not match.
        allow(GitOperations).to receive(:version_tags).and_return(versions("2.5.0", "1.5.3", "1.5.0"))

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq(["Newer version of a/b: 1.5.3\nSource: #{manifest}"])
      end
    end

    it "does not report a pre-release as the newest version in a range when pre-releases are filtered" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir, requirement: '"1.0.0"..<"3.0.0"')
        # 3.0.0-beta.1 is the absolute newest but a pre-release; report 2.0.0.
        allow(GitOperations).to receive(:version_tags).and_return(versions("3.0.0-beta.1", "2.0.0", "1.0.0"))

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq(["Newer version of a/b: 2.0.0\nSource: #{manifest}"])
      end
    end

    it "does not emit an empty warning when no available version satisfies the constraint" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        # Only a newer *major* exists, which an upToNextMajor (`from:`) constraint excludes.
        allow(GitOperations).to receive(:version_tags).and_return(versions("2.0.0"))

        warnings = checker.check_manifests([manifest])

        expect(warnings).to eq([])
      end
    end

    it "skips malformed package entries with nil requirements", :aggregate_failures do
      remote_packages = {
        "github.com/a/b" => { "repository_url" => "https://github.com/a/b", "requirement" => nil }
      }

      checker.send(:check_packages, remote_packages, "github.com/a/b" => "1.0.0")

      expect(GitOperations).not_to have_received(:version_tags)
      expect(checker.instance_variable_get(:@warnings)).to eq([])
    end

    it "uses fresh persistent version tag cache entries before fetching", :aggregate_failures do
      Dir.mktmpdir do |dir|
        checker.version_tags_cache_dir = dir
        persistent_cache = VersionTagsPersistentCache.new(directory: dir, ttl_seconds: 21_600)
        persistent_cache.write(persistent_cache_key, versions("1.1.0", "1.0.0"))

        checker.send(:check_packages, cache_remote_packages, cache_resolved_versions)

        expect(GitOperations).not_to have_received(:version_tags)
        expect(checker.instance_variable_get(:@warnings)).to eq(["Newer version of acme/shared: 1.1.0"])
      end
    end

    it "refetches expired persistent cache entries and overwrites them", :aggregate_failures do
      Dir.mktmpdir do |dir|
        repository_url = "https://user:token@github.com/acme/shared"
        checker.version_tags_cache_dir = dir
        checker.version_tags_cache_ttl_seconds = 60
        cache_record_writer.call(dir, repository_url:, fetched_at: "1970-01-01T00:00:00Z", tags: ["1.1.0", "1.0.0"])
        allow(GitOperations).to receive(:version_tags).with(repository_url).and_return(versions("1.2.0", "1.0.0"))

        checker.send(:check_packages, cache_remote_packages(repository_url), cache_resolved_versions)

        cache_contents = Dir.children(dir)
          .map { |entry| File.read(File.join(dir, entry)) }
          .join("\n")
        expect(GitOperations).to have_received(:version_tags).with(repository_url)
        expect(checker.instance_variable_get(:@warnings)).to eq(["Newer version of acme/shared: 1.2.0"])
        expect(cache_contents).to include("1.2.0")
        expect(cache_contents).not_to include("user:token")
      end
    end

    it "ignores persistent cache entries when the TTL is zero", :aggregate_failures do
      Dir.mktmpdir do |dir|
        checker.version_tags_cache_dir = dir
        checker.version_tags_cache_ttl_seconds = 0
        cache_record_writer.call(dir, tags: ["1.1.0", "1.0.0"])
        allow(GitOperations).to receive(:version_tags).with("https://github.com/acme/shared").and_return(versions("1.2.0", "1.0.0"))

        checker.send(:check_packages, cache_remote_packages, cache_resolved_versions)

        expect(GitOperations).to have_received(:version_tags).with("https://github.com/acme/shared")
        expect(checker.instance_variable_get(:@warnings)).to eq(["Newer version of acme/shared: 1.2.0"])
      end
    end

    it "does not turn exhausted version tag lookup failures into no updates", :aggregate_failures do
      allow(GitOperations).to receive(:version_tags)
        .with("https://github.com/acme/shared")
        .and_raise(GitOperations::LsRemoteError, "git ls-remote failed for https://github.com/acme/shared")

      expect {
        checker.send(:check_packages, cache_remote_packages, cache_resolved_versions)
      }.to raise_error(GitOperations::LsRemoteError)
      expect(checker.instance_variable_get(:@warnings)).to eq([])
    end

    it "raises prefetched lookup failures when no handler is configured" do
      error = GitOperations::LsRemoteError.new("prefetch failed")
      checker_class = Class.new(described_class) {
        def initialize(prefetch_error)
          super()
          @prefetch_error = prefetch_error
        end

        private

        def prefetch_version_tags(_packages)
          @version_tag_lookup_errors["github.com/acme/shared\nhttps://github.com/acme/shared"] = @prefetch_error
        end
      }

      expect {
        checker_class.new(error).send(:check_packages, cache_remote_packages, cache_resolved_versions)
      }.to raise_error(GitOperations::LsRemoteError, "prefetch failed")
    end

    it "routes lookup failures to the handler and keeps checking other packages", :aggregate_failures do
      failures = []
      checker.lookup_failure_handler = ->(package, error) { failures << [package.name, error.message] }
      allow(GitOperations).to receive(:version_tags)
        .with("https://github.com/acme/shared")
        .and_raise(GitOperations::LsRemoteError, "git ls-remote failed for https://github.com/acme/shared")
      allow(GitOperations).to receive(:version_tags)
        .with("https://github.com/acme/other")
        .and_return(versions("1.2.0", "1.0.0"))
      remote_packages = cache_remote_packages.merge(
        "github.com/acme/other" => {
          "repository_url" => "https://github.com/acme/other",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
        }
      )
      resolved_versions = cache_resolved_versions.merge("github.com/acme/other" => "1.0.0")

      expect {
        checker.send(:check_packages, remote_packages, resolved_versions)
      }.not_to raise_error
      expect(failures).to eq([["acme/shared", "git ls-remote failed for https://github.com/acme/shared"]])
      expect(checker.instance_variable_get(:@warnings)).to eq(["Newer version of acme/other: 1.2.0"])
    end

    it "routes branch lookup failures to the handler", :aggregate_failures do
      failures = []
      checker.lookup_failure_handler = ->(package, error) { failures << [package.name, error.message] }
      allow(GitOperations).to receive(:branch_last_commit)
        .and_raise(GitOperations::LsRemoteError, "git ls-remote failed for branch")

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_branch(dir)

        expect { checker.check_manifests([manifest]) }
          .not_to raise_error
      end

      expect(failures).to eq([["a/b", "git ls-remote failed for branch"]])
    end

    it "fails a dependency shared by several manifests once: one fetch, one handler call", :aggregate_failures do
      failures = []
      checker.lookup_failure_handler = ->(package, error) { failures << [package.name, error.message] }
      lookup_count = 0
      allow(GitOperations).to receive(:version_tags).with("https://github.com/a/b") {
        lookup_count += 1
        raise(GitOperations::LsRemoteError, "git ls-remote failed for https://github.com/a/b")
      }

      Dir.mktmpdir do |first_dir|
        Dir.mktmpdir do |second_dir|
          manifests = [
            ManifestPackageFixture.write_version(first_dir),
            ManifestPackageFixture.write_version(second_dir),
          ]

          expect { checker.check_manifests(manifests) }
            .not_to raise_error
        end
      end

      expect(lookup_count).to eq(1)
      expect(failures).to eq([["a/b", "git ls-remote failed for https://github.com/a/b"]])
    end

    it "routes malformed resolved files to the handler and continues with remaining pins", :aggregate_failures do
      stub_default_versions
      malformed = []
      checker.malformed_resolved_handler = ->(path, error) { malformed << [path, error.message] }

      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        bad_resolved = File.join(dir, "Bad.resolved")
        File.write(bad_resolved, "{not json")

        warnings = checker.check_manifests([manifest], [File.join(dir, "Package.resolved"), bad_resolved])

        expect(warnings).to eq(["Newer version of a/b: 1.1.0\nSource: #{manifest}"])
        expect(malformed.size).to eq(1)
        expect(malformed.first.first).to eq(bad_resolved)
        expect(malformed.first.last).to include("Malformed Package.resolved at #{bad_resolved}")
      end
    end

    it "raises for malformed resolved files when no handler is configured" do
      Dir.mktmpdir do |dir|
        manifest = ManifestPackageFixture.write_version(dir)
        bad_resolved = File.join(dir, "Bad.resolved")
        File.write(bad_resolved, "{not json")

        expect {
          checker.check_manifests([manifest], [bad_resolved])
        }.to raise_error(PackageResolved::MalformedFileError)
      end
    end

    it "redacts embedded credentials when logging missing resolved versions" do
      remote_packages = {
        "github.com/acme/private" => {
          "repository_url" => "https://user:token@github.com/acme/private",
          "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
        }
      }

      expect {
        checker.send(:check_packages, remote_packages, {})
      }.to output(redacted_repository_url_log).to_stdout
    end

    it "redacts embedded credentials when logging unsupported dependency rules" do
      remote_packages = {
        "github.com/acme/private" => {
          "repository_url" => "https://user:token@github.com/acme/private",
          "requirement" => { "kind" => "unsupported" }
        }
      }
      allow(GitOperations).to receive(:version_tags).and_return(versions("1.1.0"))

      expect {
        checker.send(:check_packages, remote_packages, "github.com/acme/private" => "1.0.0")
      }.to output(redacted_repository_url_log).to_stdout
    end
  end

  def redacted_repository_url_log
    a_string_including("https://[REDACTED]@github.com/acme/private")
      .and(satisfy("not output raw credentials") { |output| !output.include?("user:token") })
  end

  def cache_remote_packages(repository_url = "https://github.com/acme/shared")
    {
      "github.com/acme/shared" => {
        "repository_url" => repository_url,
        "requirement" => { "kind" => "upToNextMajorVersion", "minimumVersion" => "1.0.0" }
      }
    }
  end

  def cache_resolved_versions
    { "github.com/acme/shared" => "1.0.0" }
  end
end
