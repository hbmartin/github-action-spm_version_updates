# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../action/lib/action_reporter"

RSpec.describe ActionReporter do
  def with_env(overrides)
    original = overrides.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }

    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def capture_stdout
    original_stdout = $stdout
    captured = StringIO.new
    $stdout = captured

    yield
    captured.string
  ensure
    $stdout = original_stdout
  end

  def quiet_write(reporter, env)
    capture_stdout { with_env(env) { reporter.write } }
  end

  def report_payload(warnings = [], details = [], **attributes)
    detail_records = Array(details)
    updates = Array(warnings).map.with_index do |warning, index|
      message, source = warning.to_s.split("\nSource: ", 2)
      { "message" => message, "source" => source }
        .merge(detail_records[index].to_h.transform_keys(&:to_s))
        .compact
    end

    ReportPayload.new(
      updates:,
      parse_warnings: [],
      missing_resolved: [],
      applied_updates: nil,
      timings: nil,
      **attributes
    )
  end

  def output_json(output_file)
    content = File.read(output_file)
    json = content[/updates-json<<(\S+)\n(.*?)\n\1\n/m, 2]
    JSON.parse(json)
  end

  let(:applied_json) {
    lambda { |output_file|
      content = File.read(output_file)
      json = content[/applied-updates-json<<(\S+)\n(.*?)\n\1\n/m, 2]
      JSON.parse(json)
    }
  }

  describe "#write action outputs" do
    it "writes counts, flags, and redacted updates-json to GITHUB_OUTPUT", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")
        reporter = described_class.new(report_payload(
                                         ["Newer version of foo/bar: 2.0.0"],
                                         [{ type: "version", repository_url: "https://user:token@github.com/foo/bar", current_version: "1.0.0", available_version: "2.0.0" }]
                                       ))

        quiet_write(reporter, "GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => nil)

        content = File.read(output_file)
        expect(content).to include("updates-found=1", "major-updates-found=1", "minor-updates-found=0", "patch-updates-found=0")
        expect(content).to include("blocked=false", "error-message=")
        record = output_json(output_file).first
        expect(record).to include(
          "message" => "Newer version of foo/bar: 2.0.0",
          "severity" => "major",
          "repository_url" => "https://[REDACTED]@github.com/foo/bar"
        )
      end
    end

    it "suffixes the heredoc delimiter when a record collides with it" do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")
        reporter = described_class.new(report_payload(["contains SPM_VERSION_UPDATES_JSON marker"]))

        quiet_write(reporter, "GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => nil)

        expect(File.read(output_file)).to include("updates-json<<SPM_VERSION_UPDATES_JSON_END")
      end
    end

    it "writes nothing when GITHUB_OUTPUT is not set" do
      with_env("GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => nil) {
        expect { capture_stdout { described_class.new(report_payload).write } }
          .not_to raise_error
      }
    end

    it "writes missing-resolved and applied update outputs", :aggregate_failures do
      result_class = Struct.new(:applied, :skipped, :failed, keyword_init: true) {
        def to_json_records
          applied
        end
      }
      applied = [{ "source" => "Package.swift", "package" => "foo/bar", "current_version" => "1.0.0", "available_version" => "1.1.0" }]
      reporter = described_class.new(report_payload(
                                       missing_resolved: [{ "source" => "Missing/Package.resolved", "message" => "missing" }],
                                       applied_updates: result_class.new(applied:, skipped: [], failed: [])
                                     ))

      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")

        quiet_write(reporter, "GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => nil)

        content = File.read(output_file)
        expect(content).to include("missing-resolved=1", "applied-updates=1")
        expect(applied_json.call(output_file)).to eq(applied)
      end
    end
  end

  describe "#write step summary" do
    it "reports a clean run and appends to existing summary content", :aggregate_failures do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        File.write(summary_file, "existing content\n")

        quiet_write(described_class.new(report_payload), "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to start_with("existing content\n")
        expect(content).to include("## SPM Version Updates", "All SPM dependencies are up to date.")
      end
    end

    it "numbers updates and renders source lines", :aggregate_failures do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        warnings = [
          "Newer version of foo/bar: 2.0.0\nSource: Modules/Package.swift",
          "Newer version of baz/qux: 1.1.0",
        ]

        quiet_write(described_class.new(report_payload(warnings)), "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to include("Found **2** potential dependency updates.")
        expect(content).to include("1. Newer version of foo/bar: 2.0.0\n   Source: `Modules/Package.swift`")
        expect(content).to include("2. Newer version of baz/qux: 1.1.0")
      end
    end

    it "renders compare and release links from structured details", :aggregate_failures do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        reporter = described_class.new(report_payload(
                                         ["Newer version of foo/bar: 2.0.0"],
                                         [{ type: "version", repository_url: "https://github.com/foo/bar.git", current_version: "1.0.0", available_version: "2.0.0" }]
                                       ))

        quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to include(
          "   [Compare](https://github.com/foo/bar/compare/1.0.0...2.0.0) · [Releases](https://github.com/foo/bar/releases)"
        )
      end
    end

    it "renders upgrade hint lines from structured details", :aggregate_failures do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        reporter = described_class.new(report_payload(
                                         ["Newest version of foo/bar: 2.0.0"],
                                         [{
                                           type: "above_maximum",
                                           current_version: "1.0.0",
                                           available_version: "2.0.0",
                                           suggested_command: "swift package update bar",
                                           suggested_requirement: 'from: "2.0.0"'
                                         }]
                                       ))

        quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to include("   Update: `swift package update bar`")
        expect(content).to include('   Manifest: `from: "2.0.0"`')
      end
    end

    it "omits the links line for records without a usable repository URL" do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        reporter = described_class.new(report_payload(
                                         ["Newer version of foo/bar: 2.0.0", "Newer version of baz/qux: 1.1.0"],
                                         [
                                           { type: "version", repository_url: "https://example.com/foo/bar", current_version: "1.0.0", available_version: "2.0.0" },
                                           { type: "version", current_version: "1.0.0", available_version: "1.1.0" },
                                         ]
                                       ))

        quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        expect(File.read(summary_file)).not_to include("[Compare]")
      end
    end

    it "renders missing resolved, applied updates, and timings sections", :aggregate_failures do
      result_class = Struct.new(:applied, :skipped, :failed, keyword_init: true) {
        def to_json_records
          applied
        end
      }
      timings = instance_double(Timings, summary_lines: ["", "### Timings", "", "| Phase | Duration |", "| Checks | 0.1s |"])
      reporter = described_class.new(report_payload(
                                       missing_resolved: [{ "source" => "Missing/Package.resolved", "message" => "missing" }],
                                       applied_updates: result_class.new(
                                         applied: [{ "source" => "Package.swift", "package" => "foo/bar", "current_version" => "1.0.0", "available_version" => "1.1.0" }],
                                         skipped: [],
                                         failed: []
                                       ),
                                       timings:
                                     ))

      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")

        quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to include("### Missing Package.resolved", "Missing/Package.resolved")
        expect(content).to include("### Applied updates", "| Package.swift | foo/bar | 1.0.0 -> 1.1.0 |")
        expect(content).to include("### Timings", "| Checks | 0.1s |")
      end
    end
  end

  describe "#write annotations" do
    it "emits escaped ::warning annotations with source files" do
      reporter = described_class.new(report_payload(["50% newer version\nsee notes\nSource: a,b:c/Package.swift"]))

      output = quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => nil)

      expect(output)
        .to include("::warning title=SPM dependency update,file=a%2Cb%3Ac/Package.swift::50%25 newer version%0Asee notes")
    end
  end

  describe "parse warnings" do
    let(:parse_warning) {
      ParseWarning.record(
        reason: "unrecognized_requirement",
        source: "Modules/Package.swift",
        snippet: 'url: "https://github.com/a/odd", futureRequirement: "1.0.0"'
      )
    }

    it "counts parse warnings in GITHUB_OUTPUT without inflating update counts", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")
        reporter = described_class.new(report_payload(parse_warnings: [parse_warning]))

        quiet_write(reporter, "GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => nil)

        content = File.read(output_file)
        expect(content).to include("parse-warnings=1", "updates-found=0")
        expect(output_json(output_file)).to eq([])
      end
    end

    it "writes parse-warnings=0 when nothing was skipped" do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")

        quiet_write(described_class.new(report_payload), "GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => nil)

        expect(File.read(output_file)).to include("parse-warnings=0")
      end
    end

    it "renders a parse warnings section in the step summary", :aggregate_failures do
      Dir.mktmpdir do |dir|
        summary_file = File.join(dir, "summary.md")
        reporter = described_class.new(report_payload(parse_warnings: [parse_warning]))

        quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => summary_file)

        content = File.read(summary_file)
        expect(content).to include("### Parse warnings")
        expect(content).to include("`Modules/Package.swift`: its version requirement was not recognized")
        expect(content).to include('`url: "https://github.com/a/odd", futureRequirement: "1.0.0"`')
        expect(content).to include("[open an issue](#{ParseWarning::ISSUE_URL}?")
      end
    end

    it "emits a ::warning annotation per parse warning" do
      reporter = described_class.new(report_payload(parse_warnings: [parse_warning]))

      output = quiet_write(reporter, "GITHUB_OUTPUT" => nil, "GITHUB_STEP_SUMMARY" => nil)

      expect(output).to include("::warning title=SPM manifest parse warning,file=Modules/Package.swift::")
    end
  end

  describe "#records" do
    it "merges structured detail over the parsed warning, with detail source winning", :aggregate_failures do
      reporter = described_class.new(report_payload(
                                       ["Newer version of foo/bar: 2.0.0\nSource: parsed/Package.swift"],
                                       [{ source: "detail/Package.swift", package: "foo/bar" }]
                                     ))

      record = reporter.records.first
      expect(record["message"]).to eq("Newer version of foo/bar: 2.0.0")
      expect(record["source"]).to eq("detail/Package.swift")
      expect(record["package"]).to eq("foo/bar")
    end

    it "computes severity counts from detail versions" do
      reporter = described_class.new(report_payload(
                                       ["update one", "update two"],
                                       [
                                         { type: "version", current_version: "1.0.0", available_version: "2.0.0" },
                                         { type: "version", current_version: "1.0.0", available_version: "1.1.0" },
                                       ]
                                     ))

      expect(reporter.severity_counts).to eq("major" => 1, "minor" => 1, "patch" => 0)
    end
  end

  describe "BlockedReport" do
    it "writes zeroed outputs, the error message, and an error annotation", :aggregate_failures do
      Dir.mktmpdir do |dir|
        output_file = File.join(dir, "output.txt")
        summary_file = File.join(dir, "summary.md")

        output = capture_stdout {
          with_env("GITHUB_OUTPUT" => output_file, "GITHUB_STEP_SUMMARY" => summary_file) {
            described_class::BlockedReport.write("host evil.example is not allowed")
          }
        }

        content = File.read(output_file)
        expect(content).to include("updates-found=0", "major-updates-found=0", "parse-warnings=0", "blocked=true")
        expect(content).to include("error-message<<", "host evil.example is not allowed")
        expect(output_json(output_file)).to eq([])
        expect(File.read(summary_file)).to include("blocked", "host evil.example is not allowed")
        expect(output).to include("::error title=SPM version check blocked::host evil.example is not allowed")
      end
    end
  end
end
