# frozen_string_literal: true

require "json"
require "spm_version_updates/package_resolved"
require "tmpdir"

RSpec.describe PackageResolved do
  def write_resolved(dir, contents)
    path = File.join(dir, "Package.resolved")
    File.write(path, contents.kind_of?(String) ? contents : JSON.generate(contents))
    path
  end

  def pin(url_key, url, state)
    { "identity" => "fixture", "kind" => "remoteSourceControl", url_key => url, "state" => state }
  end

  describe ".versions_from" do
    it "parses v2 format pins with normalized repository URLs" do
      Dir.mktmpdir do |dir|
        nuke_pin = pin("location", "https://github.com/kean/Nuke.git", { "revision" => "abc123", "version" => "12.1.6" })
        path = write_resolved(dir, { "version" => 2, "pins" => [nuke_pin] })

        expect(described_class.versions_from(path)).to eq("github.com/kean/Nuke" => "12.1.6")
      end
    end

    it "parses v1 format pins nested under object" do
      Dir.mktmpdir do |dir|
        v1_pin = pin("repositoryURL", "https://github.com/gonzalezreal/NetworkImage", { "version" => "3.1.0" })
        path = write_resolved(dir, { "version" => 1, "object" => { "pins" => [v1_pin] } })

        expect(described_class.versions_from(path)).to eq("github.com/gonzalezreal/NetworkImage" => "3.1.0")
      end
    end

    it "falls back to the revision when a pin has no version" do
      Dir.mktmpdir do |dir|
        branch_pin = pin("location", "git@github.com:hbmartin/analytics-swift.git", { "branch" => "main", "revision" => "81ed4a83" })
        path = write_resolved(dir, { "version" => 2, "pins" => [branch_pin] })

        expect(described_class.versions_from(path)).to eq("git@github.com:hbmartin/analytics-swift" => "81ed4a83")
      end
    end

    it "returns an empty hash when the file has no pins" do
      Dir.mktmpdir do |dir|
        path = write_resolved(dir, { "version" => 3 })

        expect(described_class.versions_from(path)).to eq({})
      end
    end

    it "raises a named error for malformed JSON", :aggregate_failures do
      Dir.mktmpdir do |dir|
        path = write_resolved(dir, "{ not json")

        expect { described_class.versions_from(path) }
          .to raise_error(described_class::MalformedFileError) { |error|
                expect(error.message).to include("Malformed Package.resolved at #{path}")
                expect(error.path).to eq(path)
              }
      end
    end
  end

  describe ".pins_from" do
    it "returns normalized pin records with original repository URLs" do
      Dir.mktmpdir do |dir|
        nuke_pin = pin("location", "https://github.com/kean/Nuke.git", { "revision" => "abc123", "version" => "12.1.6" })
        path = write_resolved(dir, { "version" => 2, "pins" => [nuke_pin] })

        expect(described_class.pins_from(path)).to eq(
          [
            {
              "normalized_url" => "github.com/kean/Nuke",
              "repository_url" => "https://github.com/kean/Nuke.git",
              "version" => "12.1.6",
              "revision" => "abc123"
            },
          ]
        )
      end
    end

    it "supports v1 Package.resolved repositoryURL pins" do
      Dir.mktmpdir do |dir|
        v1_pin = pin("repositoryURL", "https://github.com/gonzalezreal/NetworkImage", { "version" => "3.1.0" })
        path = write_resolved(dir, { "version" => 1, "object" => { "pins" => [v1_pin] } })

        expect(described_class.pins_from(path).first).to include(
          "normalized_url" => "github.com/gonzalezreal/NetworkImage",
          "repository_url" => "https://github.com/gonzalezreal/NetworkImage",
          "version" => "3.1.0"
        )
      end
    end
  end
end
