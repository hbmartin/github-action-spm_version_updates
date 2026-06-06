# frozen_string_literal: true

require_relative "../../lib/spm_checker"

# Xcode-project mode coverage for SpmChecker#check_for_updates, exercising the
# XcodeParser path against the committed .xcodeproj fixtures (including the v1
# Package.resolved format, ssh/.git URLs, and the dual resolved-file locations).
# Git access is stubbed so these run without network access.
RSpec.describe SpmChecker, "#check_for_updates" do
  def versions(*strings)
    strings.map { |string| SpmVersionUpdates::Semver.new(string) }
      .sort.reverse
  end

  def fixture(name)
    File.expand_path("../support/fixtures/#{name}.xcodeproj", __dir__)
  end

  subject(:checker) { described_class.new }

  it "reports newer versions for up to next major" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))

    expect(checker.check_for_updates(fixture("UpToNextMajor"))).to eq(["Newer version of kean/Nuke: 12.1.7"])
  end

  it "queries git with the original scheme-bearing URL, not the normalized match key" do
    received = []
    allow(GitOperations).to receive(:version_tags) { |url|
                              received << url
                              versions("12.1.7", "12.1.6")
                            }

    checker.check_for_updates(fixture("UpToNextMajor"))

    # Regression: the normalized key "github.com/kean/Nuke" is not a valid git
    # remote; git ls-remote needs the original "https://..." URL.
    expect(received).to eq(["https://github.com/kean/Nuke"])
  end

  it "reports newer versions for exact constraints when check_when_exact is set" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))
    checker.check_when_exact = true

    expect(checker.check_for_updates(fixture("ExactVersion"))).to eq(
      ["Newer version of kean/Nuke: 12.1.7 (but this package is set to exact version 12.1.6)"]
    )
  end

  it "does not report exact constraints by default" do
    expect(checker.check_for_updates(fixture("ExactVersion"))).to eq([])
  end

  it "does not warn for exact constraints when only pre-release versions exist" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.2.0-beta.1"))
    checker.check_when_exact = true

    expect(checker.check_for_updates(fixture("ExactVersion"))).to eq([])
  end

  it "reports newer versions within a version range" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("13.0.0", "12.1.7", "12.1.6"))

    expect(checker.check_for_updates(fixture("VersionRange"))).to eq(["Newer version of kean/Nuke: 12.1.7"])
  end

  it "reports newer commits for branch-pinned dependencies" do
    allow(GitOperations).to receive(:branch_last_commit).and_return("d658f302f56abfd7a163e3b5f44de39b780a64c2")

    expect(checker.check_for_updates(fixture("Branch"))).to eq(
      ["Newer commit available for kean/Nuke (main): d658f302f56abfd7a163e3b5f44de39b780a64c2"]
    )
  end

  it "does not report commit/revision-pinned dependencies by default" do
    expect(checker.check_for_updates(fixture("Commit"))).to eq([])
  end

  it "reports the above-maximum version when report_above_maximum is set" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("13.0.0", "12.1.6"))
    checker.report_above_maximum = true

    expect(checker.check_for_updates(fixture("UpToNextMajor"))).to eq(
      ["Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version)"]
    )
  end

  it "reports a non-pre-release as the above-maximum version when pre-releases are filtered" do
    # 14.0.0-beta.1 is the absolute newest but is a pre-release; the message must
    # report 13.0.0 (the newest release) rather than the beta.
    allow(GitOperations).to receive(:version_tags).and_return(versions("14.0.0-beta.1", "13.0.0", "12.1.6"))
    checker.report_above_maximum = true

    expect(checker.check_for_updates(fixture("UpToNextMajor"))).to eq(
      ["Newest version of kean/Nuke: 13.0.0 (but this package is configured up to the next major version)"]
    )
  end

  it "reads version=1 Package.resolved files" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("3.1.3"))

    expect(checker.check_for_updates(fixture("PackageV1"))).to eq(["Newer version of gonzalezreal/NetworkImage: 3.1.3"])
  end

  it "handles ssh and .git repository URLs" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))

    expect(checker.check_for_updates(fixture("MangledUrl"))).to eq(["Newer version of kean/Nuke: 12.1.7"])
  end

  it "allows ssh repository URLs when their host is configured" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))
    checker.allow_hosts = ["github.com"]

    expect(checker.check_for_updates(fixture("MangledUrl"))).to eq(["Newer version of kean/Nuke: 12.1.7"])
  end

  it "merges both Package.resolved locations" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))

    expect(checker.check_for_updates(fixture("AlsoHasXcworkspace"))).to eq(
      [
        "Newer version of kean/Nuke: 12.1.7",
        "Newer version of Something/Else: 12.1.7",
      ]
    )
  end

  it "skips ignored repositories" do
    allow(GitOperations).to receive(:version_tags).and_return(versions("12.1.7", "12.1.6"))
    checker.ignore_repos = ["ssh://github.com/kean/Nuke.git"]

    expect(checker.check_for_updates(fixture("UpToNextMajor"))).to eq([])
  end

  it "raises when no Package.resolved is present" do
    expect {
      checker.check_for_updates(fixture("NoPackagesResolved"))
    }.to raise_error(XcodeParser::CouldNotFindResolvedFile)
  end
end
