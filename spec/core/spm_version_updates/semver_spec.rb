# frozen_string_literal: true

require "spm_version_updates/semver"

RSpec.describe SpmVersionUpdates::Semver do
  def semver(value)
    described_class.new(value)
  end

  it "normalizes two-component versions to patch-zero versions" do
    expect(semver("1.0").to_s).to eq("1.0.0")
  end

  it "normalizes v-prefixed versions" do
    expect(semver("v1.2.3").to_s).to eq("1.2.3")
  end

  it "orders canonical SemVer pre-release identifiers" do
    versions = [
      "1.0.0",
      "1.0.0-rc.1",
      "1.0.0-beta.11",
      "1.0.0-beta.2",
      "1.0.0-beta",
      "1.0.0-alpha.beta",
      "1.0.0-alpha.1",
      "1.0.0-alpha",
    ].map { |version| semver(version) }

    expect(versions.sort.map(&:to_s)).to eq(
      [
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
      ]
    )
  end

  it "orders date-style pre-release identifiers without raising" do
    versions = [
      semver("600.0.0-prerelease-2024-08-14"),
      semver("600.0.0-prerelease-2024-09-04"),
    ]

    expect(versions.sort.map(&:to_s)).to eq(
      [
        "600.0.0-prerelease-2024-08-14",
        "600.0.0-prerelease-2024-09-04",
      ]
    )
  end

  it "preserves build metadata while comparing by SemVer precedence", :aggregate_failures do
    first = semver("1.2.3+build.1")
    second = semver("1.2.3+build.2")

    expect(first.to_s).to eq("1.2.3+build.1")
    expect(second.to_s).to eq("1.2.3+build.2")
    expect(first).to eq(second)
  end

  it "exposes numeric version parts and pre-release metadata", :aggregate_failures do
    version = semver("12.2.0-beta.1")

    expect(version.major).to eq(12)
    expect(version.minor).to eq(2)
    expect(version.patch).to eq(0)
    expect(version.pre).to eq("beta.1")
    expect(semver("12.2.0").pre).to be_nil
  end

  it "raises ArgumentError for invalid versions" do
    expect {
      semver("not-a-version")
    }.to raise_error(ArgumentError)
  end
end
