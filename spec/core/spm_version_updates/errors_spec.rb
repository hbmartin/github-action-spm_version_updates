# frozen_string_literal: true

require "spm_version_updates"

RSpec.describe(SpmVersionUpdates::Error) do
  it "categorizes every concrete error class", :aggregate_failures do
    expect(GitOperations::LsRemoteError).to(be < SpmVersionUpdates::NetworkError)
    expect(ManifestParser::ManifestPathMustBeSet).to(be < SpmVersionUpdates::ConfigurationError)
    expect(ManifestParser::CouldNotFindManifest).to(be < SpmVersionUpdates::FileNotFoundError)
    expect(ManifestParser::CouldNotFindResolvedFile).to(be < SpmVersionUpdates::FileNotFoundError)
    expect(PackageResolved::MalformedFileError).to(be < SpmVersionUpdates::ParseError)
    expect(SpmChecker::DisallowedRepositoryHost).to(be < SpmVersionUpdates::PolicyError)
    expect(XcodeParser::XcodeprojPathMustBeSet).to(be < SpmVersionUpdates::ConfigurationError)
    expect(XcodeParser::CouldNotFindResolvedFile).to(be < SpmVersionUpdates::FileNotFoundError)
  end

  it "keeps category errors rescuable as StandardError", :aggregate_failures do
    expect(described_class).to(be < StandardError)
    expect(SpmVersionUpdates::FileNotFoundError).to(be < described_class)
    expect(SpmVersionUpdates::ParseError).to(be < described_class)
    expect(SpmVersionUpdates::NetworkError).to(be < described_class)
    expect(SpmVersionUpdates::PolicyError).to(be < described_class)
  end

  it "keeps configuration errors rescuable as ArgumentError" do
    expect(SpmVersionUpdates::ConfigurationError).to(be < ArgumentError)
  end

  it "gives path-bearing errors readable default messages", :aggregate_failures do
    expect(ManifestParser::CouldNotFindManifest.new("a/Package.swift").message)
      .to(eq("Could not find Package.swift manifest: a/Package.swift"))
    expect(ManifestParser::CouldNotFindResolvedFile.new("a, b").message)
      .to(include("Could not find any Package.resolved file (looked in: a, b)"))
    expect(XcodeParser::XcodeprojPathMustBeSet.new.message).to(eq("Invalid Xcode project path"))
    expect(XcodeParser::CouldNotFindResolvedFile.new.message)
      .to(eq("Could not find a Package.resolved file for the Xcode project"))
    expect(ManifestParser::ManifestPathMustBeSet.new.message).to(eq("package-manifest-paths must be set"))
  end
end
