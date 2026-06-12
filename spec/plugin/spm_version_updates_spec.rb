# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require File.expand_path("../coverage_helper", __dir__)
require File.expand_path("spec_helper", __dir__)

# Spec namespace matching Danger's plugin lookup.
module Danger
  describe Danger::DangerSpmVersionUpdates do
    it "is a plugin" do
      expect(described_class.new(nil)).to be_a Danger::Plugin
    end

    describe "with Dangerfile" do
      def versions(*strings)
        strings.map { |string| SpmVersionUpdates::Semver.new(string) }
          .sort.reverse
      end

      def fixture(name)
        File.expand_path("../support/fixtures/#{name}.xcodeproj", __dir__)
      end

      def stub_versions(*strings)
        allow(GitOperations).to receive(:version_tags).and_return(versions(*strings))
      end

      def check_fixture(name)
        @my_plugin.check_for_updates(fixture(name))
      end

      def expect_warnings(*warnings)
        expect(@dangerfile.status_report[:warnings]).to eq(warnings)
      end

      def links(repo_path, current, available)
        "([Compare](https://github.com/#{repo_path}/compare/#{current}...#{available}) · " \
          "[Releases](https://github.com/#{repo_path}/releases))"
      end

      before do
        @dangerfile = testing_dangerfile
        @my_plugin = @dangerfile.spm_version_updates

        # mock the PR data
        # you can then use this, eg. github.pr_author, later in the spec
        json = File.read("#{File.dirname(__FILE__)}/../support/fixtures/github_pr.json")
        allow(@my_plugin.github).to receive(:pr_json).and_return(json)
      end

      it "Does not report pre-release versions by default" do
        stub_versions("12.1.6", "12.2.0-beta.1", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        check_fixture("ExactVersion")

        expect_warnings
      end

      it "Does not report empty exact-version warnings when every available version is filtered out" do
        stub_versions("12.2.0-beta.1", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        check_fixture("ExactVersion")

        expect_warnings
      end

      it "Reports new versions for exact versions when configured" do
        stub_versions("12.1.6", "12.1.7")

        @my_plugin.check_when_exact = true
        check_fixture("ExactVersion")

        expect_warnings(
          "Newer version of kean/Nuke: 12.1.7 (but this package is set to exact version 12.1.6) " \
          "#{links('kean/Nuke', '12.1.6', '12.1.7')}"
        )
      end

      it "Reports pre-release versions for exact versions when configured" do
        stub_versions("12.1.6", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        @my_plugin.report_pre_releases = true
        check_fixture("ExactVersion")

        expect_warnings(
          "Newer version of kean/Nuke: 12.2.0-beta.2 (but this package is set to exact version 12.1.6) " \
          "#{links('kean/Nuke', '12.1.6', '12.2.0-beta.2')}"
        )
      end

      it "Reports new versions for up to next major" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("UpToNextMajor")

        expect_warnings("Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.1.6', '12.1.7')}")
      end

      it "Reports pre-release versions for up to next major when configured" do
        stub_versions("12.1.6", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        @my_plugin.report_pre_releases = true
        check_fixture("UpToNextMajor")

        expect_warnings("Newer version of kean/Nuke: 12.2.0-beta.2 #{links('kean/Nuke', '12.1.6', '12.2.0-beta.2')}")
      end

      it "Does not report pre-release versions for up to next major" do
        stub_versions("12.1.6", "12.2.0-beta.2", "13.0.0")

        check_fixture("UpToNextMajor")

        expect_warnings
      end

      it "Does not report pre-release versions as the newest up to next major version" do
        stub_versions("12.1.6", "12.2.0-beta.1")

        check_fixture("UpToNextMajor")

        expect_warnings
      end

      it "Does not report new versions for up to next major when next version is major" do
        stub_versions("12.1.6", "13.0.0")

        check_fixture("UpToNextMajor")

        expect_warnings
      end

      it "Does report new versions for up to next major when next version is major and configured" do
        stub_versions("12.1.6", "13.0.0")

        @my_plugin.report_above_maximum = true
        check_fixture("UpToNextMajor")

        expect_warnings(
          "Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version) " \
          "#{links('kean/Nuke', '12.1.6', '13.0.0')}"
        )
      end

      it "Reports the filtered above-maximum version for up to next major" do
        stub_versions("12.1.6", "13.0.0", "14.0.0-beta.1")

        @my_plugin.report_above_maximum = true
        check_fixture("UpToNextMajor")

        expect_warnings(
          "Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version) " \
          "#{links('kean/Nuke', '12.1.6', '13.0.0')}"
        )
      end

      it "Does not match up to next minor versions from a different major" do
        stub_versions("1.5.0", "2.5.0")

        Dir.mktmpdir do |dir|
          File.write(
            File.join(dir, "Package.swift"),
            '.package(url: "https://github.com/kean/Nuke", .upToNextMinor(from: "1.5.0"))'
          )
          File.write(
            File.join(dir, "Package.resolved"),
            <<~JSON
              {
                "pins" : [
                  {
                    "identity" : "nuke",
                    "kind" : "remoteSourceControl",
                    "location" : "https://github.com/kean/Nuke",
                    "state" : { "revision" : "0000", "version" : "1.5.0" }
                  }
                ],
                "version" : 2
              }
            JSON
          )

          @my_plugin.check_manifests(File.join(dir, "Package.swift"))
        end

        expect_warnings
      end

      it "Reports new versions for ranges" do
        stub_versions("13.0.0", "12.1.6", "12.1.7")

        check_fixture("VersionRange")

        expect_warnings("Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.1.6', '12.1.7')}")
      end

      it "Does not report pre-release versions as the newest range version" do
        stub_versions("12.1.6", "12.2.0-beta.1")

        check_fixture("VersionRange")

        expect_warnings
      end

      it "Does not report empty range warnings when no reportable version satisfies the range" do
        stub_versions("13.0.0")

        check_fixture("VersionRange")

        expect_warnings
      end

      it "Reports new versions for branches" do
        allow(GitOperations).to receive(:branch_last_commit)
          .and_return "d658f302f56abfd7a163e3b5f44de39b780a64c2"

        check_fixture("Branch")

        expect_warnings(
          "Newer commit available for kean/Nuke (main): d658f302f56abfd7a163e3b5f44de39b780a64c2 " \
          "#{links('kean/Nuke', '3f666f120b63ea7de57d42e9a7c9b47f8e7a290b', 'd658f302f56abfd7a163e3b5f44de39b780a64c2')}"
        )
      end

      it "Does not report when pinned to commit" do
        stub_versions("12.1.6")

        check_fixture("Commit")

        expect_warnings
      end

      it "Prints to stdout when resolved version is unexpectedly null" do
        stub_versions("12.1.6")

        expect {
          check_fixture("PackageV1Commit")
        }.to output(
          %r{Unable to extract semver from 12f19662426d0434d6c330c6974d53e2eb10ecd9 for AliSoftware/OHHTTPStubs.*}
        ).to_stdout
      end

      it "Does not fail when resolved version is unexpectedly null" do
        stub_versions("12.1.6")

        check_fixture("PackageV1Commit")
        expect_warnings
      end

      it "Does not crash or warn when resolved version is missing from xcodeproj" do
        check_fixture("NoResolvedVersion")

        expect_warnings
      end

      it "Prints to stdout when resolved version is missing from xcodeproj" do
        expect {
          check_fixture("NoResolvedVersion")
        }.to output(
          %r{Unable to locate the current version for kean/Nuke.*}
        ).to_stdout
      end

      it "Reports new versions for both possible Package.resolved locations" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("AlsoHasXcworkspace")

        expect_warnings(
          "Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.1.6', '12.1.7')}",
          "Newer version of Something/Else: 12.1.7 #{links('Something/Else', '12.1.6', '12.1.7')}"
        )
      end

      it "Warns and keeps checking other packages when a version lookup fails" do
        allow(GitOperations).to receive(:version_tags) { |repo_url|
          raise(GitOperations::LsRemoteError, "fatal: could not read from remote") if repo_url.include?("kean/Nuke")

          versions("12.1.6", "12.1.7")
        }

        check_fixture("AlsoHasXcworkspace")

        expect_warnings(
          "Unable to check kean/Nuke (github.com/kean/Nuke) for updates: fatal: could not read from remote",
          "Newer version of Something/Else: 12.1.7 #{links('Something/Else', '12.1.6', '12.1.7')}"
        )
      end

      it "Warns and skips malformed Package.resolved files while processing valid ones", :aggregate_failures do
        stub_versions("12.1.6", "12.1.7")

        Dir.mktmpdir do |dir|
          xcodeproj_path = File.join(dir, "App.xcodeproj")
          FileUtils.mkdir_p(xcodeproj_path)
          FileUtils.cp(File.join(fixture("UpToNextMajor"), "project.pbxproj"), xcodeproj_path)

          valid_resolved_dir = File.join(xcodeproj_path, "project.xcworkspace/xcshareddata/swiftpm")
          FileUtils.mkdir_p(valid_resolved_dir)
          File.write(
            File.join(valid_resolved_dir, "Package.resolved"),
            <<~JSON
              {
                "pins" : [
                  {
                    "identity" : "nuke",
                    "kind" : "remoteSourceControl",
                    "location" : "https://github.com/kean/Nuke",
                    "state" : { "revision" : "0000", "version" : "12.1.6" }
                  }
                ],
                "version" : 2
              }
            JSON
          )

          malformed_resolved_dir = File.join(dir, "App.xcworkspace/xcshareddata/swiftpm")
          FileUtils.mkdir_p(malformed_resolved_dir)
          malformed_path = File.join(malformed_resolved_dir, "Package.resolved")
          File.write(malformed_path, "{ not json")

          @my_plugin.check_for_updates(xcodeproj_path)

          warnings = @dangerfile.status_report[:warnings]
          expect(warnings.size).to eq(2)
          expect(warnings.first).to include("Skipping malformed Package.resolved file #{malformed_path}")
          expect(warnings.last).to eq("Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.1.6', '12.1.7')}")
        end
      end

      it "Raises error when xcodeproj_path is nil" do
        expect {
          @my_plugin.check_for_updates(nil)
        }.to raise_error(XcodeParser::XcodeprojPathMustBeSet)
      end

      it "Raises error when no Packages.resolved are present" do
        expect {
          check_fixture("NoPackagesResolved")
        }.to raise_error(XcodeParser::CouldNotFindResolvedFile)
      end

      it "Reports new versions with ssh and/or .git URLs" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("MangledUrl")

        expect_warnings("Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.1.6', '12.1.7')}")
      end

      it "Does not report new versions when repo was ignored" do
        stub_versions("12.1.6", "12.1.7")

        @my_plugin.ignore_repos = ["ssh://github.com/kean/Nuke.git"]
        check_fixture("UpToNextMajor")

        expect_warnings
      end

      it "Suppresses semantic warnings with repo rules from a YAML file" do
        stub_versions("12.1.6", "12.1.7")

        Dir.mktmpdir do |dir|
          rules_path = File.join(dir, "repo-rules.yml")
          File.write(
            rules_path,
            <<~YAML
              repositories:
                - url: "ssh://github.com/kean/Nuke.git"
                  ignore-until: "13.0.0"
            YAML
          )

          @my_plugin.repo_rules_path = rules_path
          check_fixture("UpToNextMajor")
        end

        expect_warnings
      end

      it "Does not suppress branch warnings with repo rules" do
        allow(GitOperations).to receive(:branch_last_commit)
          .and_return "d658f302f56abfd7a163e3b5f44de39b780a64c2"

        Dir.mktmpdir do |dir|
          rules_path = File.join(dir, "repo-rules.yml")
          File.write(
            rules_path,
            <<~YAML
              repositories:
                - url: "ssh://github.com/kean/Nuke.git"
                  allowed-updates: "patch"
            YAML
          )

          @my_plugin.repo_rules_path = rules_path
          check_fixture("Branch")
        end

        expect_warnings(
          "Newer commit available for kean/Nuke (main): d658f302f56abfd7a163e3b5f44de39b780a64c2 " \
          "#{links('kean/Nuke', '3f666f120b63ea7de57d42e9a7c9b47f8e7a290b', 'd658f302f56abfd7a163e3b5f44de39b780a64c2')}"
        )
      end

      it "Reports new versions for version=1 Package.resolved" do
        stub_versions("3.1.3")

        check_fixture("PackageV1")

        expect_warnings("Newer version of gonzalezreal/NetworkImage: 3.1.3 #{links('gonzalezreal/NetworkImage', '3.1.2', '3.1.3')}")
      end

      describe "#check_manifests" do
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

        it "Checks dependencies across multiple manifests with links and source attribution" do
          @my_plugin.check_when_exact = true
          @my_plugin.check_manifests([modules_manifest, build_tools_manifest])

          expect_warnings(
            "Newer version of onevcat/Kingfisher: 7.10.2 #{links('onevcat/Kingfisher', '7.0.0', '7.10.2')}" \
            "<br>Source: `#{modules_manifest}`<br>Update: `swift package update kingfisher`",
            "Newer version of apple/swift-argument-parser: 1.3.0 (but this package is set to exact version 1.2.3) " \
            "#{links('apple/swift-argument-parser', '1.2.3', '1.3.0')}<br>Source: `#{modules_manifest}`" \
            "<br>Update: `swift package update swift-argument-parser`",
            "Newer version of kean/Nuke: 12.1.7 #{links('kean/Nuke', '12.0.0', '12.1.7')}" \
            "<br>Source: `#{modules_manifest}`<br>Update: `swift package update nuke`",
            "Newer commit available for hbmartin/analytics-swift (main): 1111111111111111111111111111111111111111 " \
            "#{links('hbmartin/analytics-swift', '0000000000000000000000000000000000000000', '1111111111111111111111111111111111111111')}" \
            "<br>Source: `#{modules_manifest}`<br>Update: `swift package update analytics-swift`",
            "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0 #{links('SwiftGen/SwiftGenPlugin', '6.6.0', '6.7.0')}" \
            "<br>Source: `#{build_tools_manifest}`<br>Update: `swift package update swiftgenplugin`",
            "Newer version of nicklockwood/SwiftFormat: 0.52.7 #{links('nicklockwood/SwiftFormat', '0.52.0', '0.52.7')}" \
            "<br>Source: `#{build_tools_manifest}`<br>Update: `swift package update swiftformat`"
          )
        end

        it "Accepts a single manifest path string" do
          @my_plugin.check_manifests(build_tools_manifest)

          expect(@dangerfile.status_report[:warnings].size).to eq(2)
        end

        it "Accepts explicit resolved paths" do
          @my_plugin.check_manifests(
            build_tools_manifest,
            File.join(manifests_dir, "BuildTools", "Package.resolved")
          )

          expect(@dangerfile.status_report[:warnings].size).to eq(2)
        end

        it "Respects ignore_repos with mangled URLs" do
          @my_plugin.ignore_repos = [
            "ssh://github.com/SwiftGen/SwiftGenPlugin.git",
            "https://github.com/nicklockwood/SwiftFormat",
          ]
          @my_plugin.check_manifests(build_tools_manifest)

          expect_warnings
        end

        it "Suppresses semantic warnings with repo rules from a YAML file" do
          Dir.mktmpdir do |dir|
            rules_path = File.join(dir, "repo-rules.yml")
            File.write(
              rules_path,
              <<~YAML
                repositories:
                  - url: "https://github.com/SwiftGen/SwiftGenPlugin"
                    ignore-until: "7.0.0"
                  - url: "https://github.com/nicklockwood/SwiftFormat"
                    ignore-until: "1.0.0"
              YAML
            )

            @my_plugin.repo_rules_path = rules_path
            @my_plugin.check_manifests(build_tools_manifest)
          end

          expect_warnings
        end

        it "Warns and keeps checking other packages when a version lookup fails" do
          allow(GitOperations).to receive(:version_tags) { |repo_url|
            raise(GitOperations::LsRemoteError, "fatal: could not read from remote") if repo_url.include?("SwiftGenPlugin")

            versions("0.53.0", "0.52.7", "0.52.0")
          }

          @my_plugin.check_manifests(build_tools_manifest)

          expect_warnings(
            "Unable to check SwiftGen/SwiftGenPlugin (github.com/SwiftGen/SwiftGenPlugin) for updates: fatal: could not read from remote",
            "Newer version of nicklockwood/SwiftFormat: 0.52.7 #{links('nicklockwood/SwiftFormat', '0.52.0', '0.52.7')}" \
            "<br>Source: `#{build_tools_manifest}`<br>Update: `swift package update swiftformat`"
          )
        end

        it "Raises when manifest_paths is nil or empty", :aggregate_failures do
          expect { @my_plugin.check_manifests(nil) }
            .to raise_error(ManifestParser::ManifestPathMustBeSet)
          expect { @my_plugin.check_manifests([]) }
            .to raise_error(ManifestParser::ManifestPathMustBeSet)
        end

        it "Raises when a manifest does not exist" do
          Dir.mktmpdir do |dir|
            missing_manifest = File.join(dir, "Package.swift")
            File.write(File.join(dir, "Package.resolved"), '{ "pins" : [], "version" : 2 }')

            expect {
              @my_plugin.check_manifests(missing_manifest)
            }.to raise_error(ManifestParser::CouldNotFindManifest)
          end
        end

        it "Raises when an expected Package.resolved is missing" do
          Dir.mktmpdir do |dir|
            manifest = File.join(dir, "Package.swift")
            File.write(manifest, '.package(url: "https://github.com/kean/Nuke", from: "1.0.0")')

            expect {
              @my_plugin.check_manifests(manifest)
            }.to raise_error(ManifestParser::CouldNotFindResolvedFile)
          end
        end
      end
    end
  end
end

def command_status(success)
  instance_double(Process::Status, success?: success)
end

def git_ls_remote_args(repo_url, options:, patterns: [])
  [GitOperations::NON_INTERACTIVE_ENV, "git", "ls-remote", *options, "--", repo_url, *patterns]
end
