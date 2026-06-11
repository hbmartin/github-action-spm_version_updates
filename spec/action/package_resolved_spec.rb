# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/package_resolved"

RSpec.describe PackageResolved do
  def write_resolved(dir, content)
    path = File.join(dir, "Package.resolved")
    File.write(path, content)
    path
  end

  describe ".versions_from" do
    it "parses v2 format pins with normalized repository URLs" do
      Dir.mktmpdir do |dir|
        path = write_resolved(
          dir,
          <<~JSON
            {
              "pins" : [
                {
                  "identity" : "nuke",
                  "kind" : "remoteSourceControl",
                  "location" : "https://github.com/kean/Nuke.git",
                  "state" : { "revision" : "abc123", "version" : "12.1.6" }
                }
              ],
              "version" : 2
            }
          JSON
        )

        expect(described_class.versions_from(path)).to eq("github.com/kean/Nuke" => "12.1.6")
      end
    end

    it "parses v1 format pins nested under object" do
      Dir.mktmpdir do |dir|
        path = write_resolved(
          dir,
          <<~JSON
            {
              "object" : {
                "pins" : [
                  {
                    "package" : "NetworkImage",
                    "repositoryURL" : "https://github.com/gonzalezreal/NetworkImage",
                    "state" : { "revision" : "def456", "version" : "3.1.0" }
                  }
                ]
              },
              "version" : 1
            }
          JSON
        )

        expect(described_class.versions_from(path)).to eq("github.com/gonzalezreal/NetworkImage" => "3.1.0")
      end
    end

    it "falls back to the revision when a pin has no version" do
      Dir.mktmpdir do |dir|
        path = write_resolved(
          dir,
          <<~JSON
            {
              "pins" : [
                {
                  "identity" : "analytics-swift",
                  "location" : "git@github.com:hbmartin/analytics-swift.git",
                  "state" : { "branch" : "main", "revision" : "81ed4a83" }
                }
              ],
              "version" : 2
            }
          JSON
        )

        expect(described_class.versions_from(path)).to eq("git@github.com:hbmartin/analytics-swift" => "81ed4a83")
      end
    end

    it "returns an empty hash when the file has no pins" do
      Dir.mktmpdir do |dir|
        path = write_resolved(dir, '{ "version" : 3 }')

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
end
