# frozen_string_literal: true

require "spm_version_updates/manifest_updater"
require "tmpdir"

RSpec.describe ManifestUpdater do
  def update(overrides = {})
    {
      "type" => "version",
      "package" => "fixture",
      "normalized_url" => "github.com/a/b",
      "repository_url" => "https://github.com/a/b",
      "available_version" => "1.2.3",
      "requirement_kind" => "upToNextMajorVersion"
    }.merge(overrides)
  end

  describe ".rewrite" do
    it "rewrites from requirements byte-exactly outside the literal", :aggregate_failures do
      content = <<~SWIFT
        dependencies: [
          .package(url: "https://github.com/a/b", from: "1.0.0"),
        ]
      SWIFT

      result = described_class.rewrite(content, [update])

      expect(result.content).to include('from: "1.2.3"')
      expect(result.content.sub("1.2.3", "1.0.0")).to eq(content)
      expect(result.applied.size).to eq(1)
      expect(result).to be_changed
    end

    it "rewrites exact and method-style requirements" do
      content = <<~SWIFT
        .package(url: "https://github.com/a/exact", .exact("1.0.0"))
        .package(url: "https://github.com/a/minor", .upToNextMinor(from: "2.0.0"))
      SWIFT
      updates = [
        update("normalized_url" => "github.com/a/exact", "available_version" => "1.0.1", "requirement_kind" => "exactVersion"),
        update("normalized_url" => "github.com/a/minor", "available_version" => "2.1.0", "requirement_kind" => "upToNextMinorVersion"),
      ]

      expect(described_class.rewrite(content, updates).content).to include('.exact("1.0.1")', '.upToNextMinor(from: "2.1.0")')
    end

    it "rewrites version range minimums for in-range updates" do
      content = '.package(url: "https://github.com/a/b", "1.0.0"..<"2.0.0")'

      result = described_class.rewrite(content, [update("requirement_kind" => "versionRange")])

      expect(result.content).to eq('.package(url: "https://github.com/a/b", "1.2.3"..<"2.0.0")')
    end

    it "rewrites half-open version range maximums for above-maximum updates" do
      content = '.package(url: "https://github.com/a/b", "1.0.0"..<"2.0.0")'
      record = update("type" => "above_maximum", "available_version" => "2.4.0", "requirement_kind" => "versionRange")

      result = described_class.rewrite(content, [record])

      expect(result.content).to eq('.package(url: "https://github.com/a/b", "1.0.0"..<"3.0.0")')
    end

    it "rewrites closed version range maximums to the available version" do
      content = '.package(url: "https://github.com/a/b", "1.0.0"..."2.0.0")'
      record = update("type" => "above_maximum", "available_version" => "2.4.0", "requirement_kind" => "versionRange")

      result = described_class.rewrite(content, [record])

      expect(result.content).to eq('.package(url: "https://github.com/a/b", "1.0.0"..."2.4.0")')
    end

    it "rewrites duplicate declarations for the same URL", :aggregate_failures do
      content = <<~SWIFT
        .package(url: "https://github.com/a/b", from: "1.0.0")
        .package(url: "https://github.com/a/b", from: "1.0.0")
      SWIFT

      result = described_class.rewrite(content, [update])

      expect(result.content.scan("1.2.3").size).to eq(2)
      expect(result.applied.size).to eq(1)
      expect(result.skipped).to be_empty
    end

    it "does not partially rewrite duplicate declarations when one match fails", :aggregate_failures do
      content = <<~SWIFT
        .package(url: "https://github.com/a/b", from: "1.0.0")
        .package(url: "https://github.com/a/b", branch: "main")
      SWIFT

      result = described_class.rewrite(content, [update])

      expect(result.content).to eq(content)
      expect(result.applied).to be_empty
      expect(result.skipped.size).to eq(1)
      expect(result.skipped.first["reason"]).to eq("requirement_mismatch")
    end

    it "applies multiple edits from right to left" do
      content = <<~SWIFT
        .package(url: "https://github.com/a/one", from: "1.0.0")
        .package(url: "https://github.com/a/two", from: "1.0.0")
      SWIFT
      updates = [
        update("normalized_url" => "github.com/a/one", "available_version" => "1.1.0"),
        update("normalized_url" => "github.com/a/two", "available_version" => "1.2.0"),
      ]

      result = described_class.rewrite(content, updates)

      expect(result.content).to include('from: "1.1.0"', 'from: "1.2.0"')
    end

    it "records skip reasons for unsupported and unsafe cases", :aggregate_failures do
      content = '.package(url: "https://github.com/a/b", branch: "main")'
      unsafe = '.package(url: "https://github.com/a/b", from: "1.\\(minor).0")'

      expect(described_class.rewrite(content, [update("requirement_kind" => "branch")]).skipped.first["reason"])
        .to eq("unsupported_requirement_kind")
      expect(described_class.rewrite(content, [update]).skipped.first["reason"])
        .to eq("requirement_mismatch")
      expect(described_class.rewrite(unsafe, [update]).skipped.first["reason"])
        .to eq("unsupported_syntax")
      expect(described_class.rewrite(content, [update("normalized_url" => "github.com/a/missing")]).skipped.first["reason"])
        .to eq("declaration_not_found")
    end
  end

  describe ".update_file" do
    it "writes only when content changes", :aggregate_failures do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Package.swift")
        File.write(path, '.package(url: "https://github.com/a/b", from: "1.0.0")')

        changed = described_class.update_file(path, [update])
        unchanged = described_class.update_file(path, [update("normalized_url" => "github.com/a/missing")])

        expect(changed).to be_changed
        expect(unchanged).not_to be_changed
        expect(File.read(path)).to include('from: "1.2.3"')
      end
    end
  end
end
