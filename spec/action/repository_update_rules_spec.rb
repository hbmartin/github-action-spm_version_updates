# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/repository_update_rules"

RSpec.describe RepositoryUpdateRules do
  def record(repository_url: "https://github.com/acme/pkg", current_version: "1.0.0", available_version: "1.1.0", type: "version")
    {
      type:,
      normalized_url: GitOperations.trim_repo_url(repository_url),
      repository_url:,
      current_version:,
      available_version:
    }
  end

  def load_yaml(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "repo-rules.yml")
      File.write(path, contents)
      return described_class.load_file(path)
    end
  end

  it "loads YAML rules and normalizes repository URLs", :aggregate_failures do
    rules = load_yaml(
      <<~YAML
        repositories:
          - url: "ssh://github.com/acme/pkg.git"
            ignore-until: "2.0.0"
      YAML
    )

    expect(rules).not_to be_empty
    expect(rules).to be_suppressed(record(available_version: "1.9.9"))
    expect(rules).not_to be_suppressed(record(available_version: "2.0.0"))
  end

  it "allows semantic updates at or below the configured allowed-updates level", :aggregate_failures do
    rules = described_class.from_hash(
      "repositories" => [
        { "url" => "https://github.com/acme/pkg", "allowed-updates" => "minor" },
      ]
    )

    expect(rules).not_to be_suppressed(record(available_version: "1.0.1"))
    expect(rules).not_to be_suppressed(record(available_version: "1.1.0"))
    expect(rules).to be_suppressed(record(available_version: "2.0.0"))
  end

  it "does not suppress branch or revision records", :aggregate_failures do
    rules = described_class.from_hash(
      "repositories" => [
        { "url" => "https://github.com/acme/pkg", "ignore-until" => "2.0.0", "allowed-updates" => "patch" },
      ]
    )

    expect(rules).not_to be_suppressed(record(type: "branch", available_version: "abcdef"))
    expect(rules).not_to be_suppressed(record(type: "revision", available_version: "3.0.0"))
  end

  it "rejects missing files" do
    expect { described_class.load_file("/tmp/does-not-exist-spm-repo-rules.yml") }
      .to raise_error(ArgumentError, /file does not exist/)
  end

  it "rejects malformed YAML" do
    expect {
      load_yaml("repositories:\n  - url: [")
    }.to raise_error(ArgumentError, /YAML is invalid/)
  end

  it "rejects non-mapping roots" do
    expect { described_class.from_hash(["not", "a", "mapping"]) }
      .to raise_error(ArgumentError, /must contain a YAML mapping/)
  end

  it "rejects unknown root and entry keys", :aggregate_failures do
    expect {
      described_class.from_hash("repositories" => [], "other" => true)
    }.to raise_error(ArgumentError, /unknown key/)

    expect {
      described_class.from_hash("repositories" => [{ "url" => "https://github.com/acme/pkg", "allowed-updates" => "minor", "why" => "noise" }])
    }.to raise_error(ArgumentError, /unknown key/)
  end

  it "rejects invalid repository lists and entries", :aggregate_failures do
    expect {
      described_class.from_hash("repositories" => "https://github.com/acme/pkg")
    }.to raise_error(ArgumentError, /repositories must be a list/)

    expect {
      described_class.from_hash("repositories" => [{ "ignore-until" => "2.0.0" }])
    }.to raise_error(ArgumentError, /url must be set/)

    expect {
      described_class.from_hash("repositories" => [{ "url" => "https://github.com/acme/pkg" }])
    }.to raise_error(ArgumentError, /must set ignore-until or allowed-updates/)
  end

  it "rejects duplicate repository entries" do
    expect {
      described_class.from_hash(
        "repositories" => [
          { "url" => "https://github.com/acme/pkg", "allowed-updates" => "minor" },
          { "url" => "ssh://github.com/acme/pkg.git", "ignore-until" => "2.0.0" },
        ]
      )
    }.to raise_error(ArgumentError, /duplicate repo-rules entry/)
  end

  it "rejects invalid semantic versions and severity names", :aggregate_failures do
    expect {
      described_class.from_hash("repositories" => [{ "url" => "https://github.com/acme/pkg", "ignore-until" => "soon" }])
    }.to raise_error(ArgumentError, /ignore-until must be a semantic version/)

    expect {
      described_class.from_hash("repositories" => [{ "url" => "https://github.com/acme/pkg", "allowed-updates" => "security" }])
    }.to raise_error(ArgumentError, /allowed-updates must be patch, minor, or major/)
  end
end
