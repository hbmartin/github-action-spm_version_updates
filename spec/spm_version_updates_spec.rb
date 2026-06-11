# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require File.expand_path("coverage_helper", __dir__)
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
        File.expand_path("support/fixtures/#{name}.xcodeproj", __dir__)
      end

      def stub_versions(*strings)
        allow(Git).to receive(:version_tags).and_return(versions(*strings))
      end

      def check_fixture(name)
        @my_plugin.check_for_updates(fixture(name))
      end

      def expect_warnings(*warnings)
        expect(@dangerfile.status_report[:warnings]).to eq(warnings)
      end

      before do
        @dangerfile = testing_dangerfile
        @my_plugin = @dangerfile.spm_version_updates

        # mock the PR data
        # you can then use this, eg. github.pr_author, later in the spec
        json = File.read("#{File.dirname(__FILE__)}/support/fixtures/github_pr.json")
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

        expect_warnings("Newer version of kean/Nuke: 12.1.7 (but this package is set to exact version 12.1.6)\n")
      end

      it "Reports pre-release versions for exact versions when configured" do
        stub_versions("12.1.6", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        @my_plugin.report_pre_releases = true
        check_fixture("ExactVersion")

        expect_warnings("Newer version of kean/Nuke: 12.2.0-beta.2 (but this package is set to exact version 12.1.6)\n")
      end

      it "Reports new versions for up to next major" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("UpToNextMajor")

        expect_warnings("Newer version of kean/Nuke: 12.1.7")
      end

      it "Reports pre-release versions for up to next major when configured" do
        stub_versions("12.1.6", "12.2.0-beta.2")

        @my_plugin.check_when_exact = true
        @my_plugin.report_pre_releases = true
        check_fixture("UpToNextMajor")

        expect_warnings("Newer version of kean/Nuke: 12.2.0-beta.2")
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

        expect_warnings("Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version)\n")
      end

      it "Reports the filtered above-maximum version for up to next major" do
        stub_versions("12.1.6", "13.0.0", "14.0.0-beta.1")

        @my_plugin.report_above_maximum = true
        check_fixture("UpToNextMajor")

        expect_warnings("Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version)\n")
      end

      it "Does not match up to next minor versions from a different major" do
        @my_plugin.send(
          :warn_for_new_versions,
          :minor,
          [
            SpmVersionUpdates::Semver.new("1.5.0"),
            SpmVersionUpdates::Semver.new("2.5.0"),
          ].sort.reverse,
          "kean/Nuke",
          "github.com/kean/Nuke",
          "1.5.0"
        )

        expect(@dangerfile.status_report[:warnings]).to eq([])
      end

      it "Reports new versions for ranges" do
        stub_versions("13.0.0", "12.1.6", "12.1.7")

        check_fixture("VersionRange")

        expect_warnings("Newer version of kean/Nuke: 12.1.7")
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
        allow(Git).to receive(:branch_last_commit)
          .and_return "d658f302f56abfd7a163e3b5f44de39b780a64c2"

        check_fixture("Branch")

        expect_warnings("Newer commit available for kean/Nuke (main): d658f302f56abfd7a163e3b5f44de39b780a64c2")
      end

      it "Does not report when pinned to commit" do
        stub_versions("12.1.6")

        check_fixture("Commit")

        expect_warnings
      end

      it "Prints to stderr when resolved version is unexpectedly null" do
        stub_versions("12.1.6")

        expect {
          check_fixture("PackageV1Commit")
        }.to output(
          %r{Unable to extract semver from 12f19662426d0434d6c330c6974d53e2eb10ecd9 for AliSoftware/OHHTTPStubs.*}
        ).to_stderr
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

      it "Prints to stderr when resolved version is missing from xcodeproj" do
        expect {
          check_fixture("NoResolvedVersion")
        }.to output(
          %r{Unable to locate the current version for kean/Nuke.*}
        ).to_stderr
      end

      it "Reports new versions for both possible Package.resolved locations" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("AlsoHasXcworkspace")

        expect_warnings(
          "Newer version of kean/Nuke: 12.1.7",
          "Newer version of Something/Else: 12.1.7"
        )
      end

      it "Warns and keeps checking other packages when a version lookup fails" do
        allow(Git).to receive(:version_tags) { |repo_url|
          raise(GitOperations::LsRemoteError, "fatal: could not read from remote") if repo_url.include?("kean/Nuke")

          versions("12.1.6", "12.1.7")
        }

        check_fixture("AlsoHasXcworkspace")

        expect_warnings(
          "Unable to check kean/Nuke (github.com/kean/Nuke) for updates: fatal: could not read from remote",
          "Newer version of Something/Else: 12.1.7"
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
          expect(warnings.last).to eq("Newer version of kean/Nuke: 12.1.7")
        end
      end

      it "Raises error when xcodeproj_path is nil" do
        expect {
          @my_plugin.check_for_updates(nil)
        }.to raise_error(Xcode::XcodeprojPathMustBeSet)
      end

      it "Raises error when no Packages.resolved are present" do
        expect {
          check_fixture("NoPackagesResolved")
        }.to raise_error(Xcode::CouldNotFindResolvedFile)
      end

      it "Ignores remote Swift package references with empty repository URLs" do
        empty_package = Object.new
        valid_package = Object.new
        local_object = Object.new

        allow(empty_package).to receive(:kind_of?)
          .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
          .and_return(true)
        allow(empty_package).to receive(:repositoryURL).and_return(" ")

        allow(valid_package).to receive(:kind_of?)
          .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
          .and_return(true)
        allow(valid_package).to receive_messages(
          repositoryURL: "https://github.com/kean/Nuke",
          requirement: { "kind" => "exactVersion" }
        )

        allow(local_object).to receive(:kind_of?)
          .with(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
          .and_return(false)

        project = instance_double(Xcodeproj::Project, objects: [empty_package, valid_package, local_object])
        allow(Xcodeproj::Project).to receive(:open).and_return(project)

        expect(Xcode.get_packages("Project.xcodeproj")).to eq(
          "github.com/kean/Nuke" => { "kind" => "exactVersion" }
        )
      end

      it "Reports new versions with ssh and/or .git URLs" do
        stub_versions("12.1.6", "12.1.7")

        check_fixture("MangledUrl")

        expect_warnings("Newer version of kean/Nuke: 12.1.7")
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
        allow(Git).to receive(:branch_last_commit)
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

        expect_warnings("Newer commit available for kean/Nuke (main): d658f302f56abfd7a163e3b5f44de39b780a64c2")
      end

      it "Transforms git tags into version list" do
        allow(Open3).to receive(:capture3)
          .with(*git_ls_remote_args(
            "https://github.com/hbmartin/danger-spm_version_updates",
            options: ["--tags", "--refs"],
            patterns: GitOperations::TAG_REF_PATTERNS
          ))
          .and_return [
            <<~TEXT,
              From git@github.com:hbmartin/danger-spm_version_updates.git
              4230ed95952b244d9d0b922d2b460fb73d985e02	refs/tags/0.1.0
              97a139d985c2edd233017f1bb26138eea25958de	refs/tags/2.0.0
            TEXT
            "",
            command_status(true),
          ]

        expect(Git.version_tags("https://github.com/hbmartin/danger-spm_version_updates")).to eq(
          [
            SpmVersionUpdates::Semver.new("2.0.0"),
            SpmVersionUpdates::Semver.new("0.1.0"),
          ]
        )
      end

      it "Raises LsRemoteError when git raises a system error" do
        allow(Open3).to receive(:capture3).and_raise(Errno::EACCES)

        expect {
          Git.version_tags("https://github.com/hbmartin/danger-spm_version_updates")
        }.to raise_error(GitOperations::LsRemoteError, /failed to start/)
          .and output(/failed to start/).to_stderr
      end

      it "Raises LsRemoteError when git ls-remote keeps failing" do
        allow(GitOperations).to receive(:sleep)
        allow(Open3).to receive(:capture3).and_return(["", "fatal: nope", command_status(false)])

        expect {
          Git.version_tags("https://github.com/hbmartin/danger-spm_version_updates")
        }.to raise_error(GitOperations::LsRemoteError, /fatal: nope/)
          .and output(/fatal: nope/).to_stderr
      end

      it "Gathers latest commit on git branch" do
        allow(Open3).to receive(:capture3)
          .with(*git_ls_remote_args(
            "https://github.com/hbmartin/danger-spm_version_updates",
            options: ["--branches"],
            patterns: ["refs/heads/main"]
          ))
          .and_return [
            <<~TEXT,
              From git@github.com:hbmartin/danger-spm_version_updates.git
              5e5c3f78ff25e7678ed7d3b25d7c60eeeee47e25	HEAD
              8c1a26f6c3822dc62e0feb655e0152e4f81e8ab3	refs/heads/hm/check-for-mangled-urls
              5e5c3f78ff25e7678ed7d3b25d7c60eeeee47e25	refs/heads/main
              ae5afe00b2d7098403dd9d87a3780cca4b4b285c	refs/pull/2/head
              8c1a26f6c3822dc62e0feb655e0152e4f81e8ab3	refs/pull/3/head
              a1fd1d464a6e5a76136d23b8e66a5a8c422dbeea	refs/pull/3/merge
              4230ed95952b244d9d0b922d2b460fb73d985e02	refs/tags/0.1.0
              97a139d985c2edd233017f1bb26138eea25958de	refs/tags/v0.1.1
              5ffb986dfbb63f90de8f9854f3d0bc35eff37c56	refs/tags/v0.1.2
            TEXT
            "",
            command_status(true),
          ]

        expect(Git.branch_last_commit("https://github.com/hbmartin/danger-spm_version_updates", "main")).to eq(
          "5e5c3f78ff25e7678ed7d3b25d7c60eeeee47e25"
        )
      end

      it "Extracts repo name from URL" do
        expect(Git.repo_name("https://github.com/hbmartin/danger-spm_version_updates")).to eq("hbmartin/danger-spm_version_updates")
      end

      it "Returns repo name from param when not URL" do
        expect(Git.repo_name("hbmartin/danger-spm_version_updates")).to eq("hbmartin/danger-spm_version_updates")
      end

      it "Reports new versions for version=1 Package.resolved" do
        stub_versions("3.1.3")

        check_fixture("PackageV1")

        expect_warnings("Newer version of gonzalezreal/NetworkImage: 3.1.3")
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
