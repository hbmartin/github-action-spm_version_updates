# frozen_string_literal: true

require "json"
require "spm_version_updates/credential_redactor"
require "spm_version_updates/update_severity"
require_relative "render/applied_updates_section"
require_relative "render/missing_resolved_section"
require_relative "render/parse_warnings_section"
require_relative "render/version_links"

# Writes GitHub Actions-visible reports for the dependency update results.
class ActionReporter
  SUMMARY_HEADING = "## SPM Version Updates"
  private_constant :SUMMARY_HEADING

  # Shared GitHub Actions output and annotation formatting.
  module WorkflowCommand
    class << self
      def env_value(key)
        value = ENV.fetch(key, "").strip
        value.empty? ? nil : value
      end

      def write_multiline_output(file, name, value)
        delimiter = "SPM_VERSION_UPDATES_JSON"
        delimiter = "#{delimiter}_END" while value.include?(delimiter)

        file.puts("#{name}<<#{delimiter}")
        file.puts(value)
        file.puts(delimiter)
      end

      def property_string(properties)
        properties
          .map { |key, value| "#{key}=#{escape_property(value)}" }
          .join(",")
      end

      def escape_data(value)
        value.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
      end

      def escape_property(value)
        escape_data(value).gsub(":", "%3A").gsub(",", "%2C")
      end

      def annotation(level, properties, message)
        "::#{level} #{property_string(properties)}::#{escape_data(message)}"
      end
    end
  end

  # Writes the report used when dependency checks are blocked before lookup.
  class BlockedReport
    OUTPUT_LINES = [
      "updates-found=0",
      "major-updates-found=0",
      "minor-updates-found=0",
      "patch-updates-found=0",
      "parse-warnings=0",
      "missing-resolved=0",
      "applied-updates=0",
      "blocked=true",
    ].freeze

    def self.write(message)
      new(message).write
    end

    def initialize(message)
      @message = message.to_s
    end

    def write
      write_outputs
      write_step_summary
      emit_error_annotation
    end

    private

    attr_reader :message

    def write_outputs
      output_path = WorkflowCommand.env_value("GITHUB_OUTPUT")
      return unless output_path

      File.open(output_path, "a") { |file| write_output_payload(file) }
    end

    def write_output_payload(file)
      empty_json = JSON.generate([])
      file.puts(OUTPUT_LINES)
      WorkflowCommand.write_multiline_output(file, "error-message", message)
      WorkflowCommand.write_multiline_output(file, "updates-json", empty_json)
      WorkflowCommand.write_multiline_output(file, "applied-updates-json", empty_json)
    end

    def write_step_summary
      summary_path = WorkflowCommand.env_value("GITHUB_STEP_SUMMARY")
      return unless summary_path

      File.open(summary_path, "a") { |file| file.puts(summary_lines) }
    end

    def summary_lines
      [
        SUMMARY_HEADING,
        "",
        "Version lookup was blocked before contacting a disallowed repository host.",
        "",
        message,
      ]
    end

    def emit_error_annotation
      puts(WorkflowCommand.annotation("error", { "title" => "SPM version check blocked" }, message))
    end
  end

  # Writes tracking-issue outputs for runs that created or updated one.
  class TrackingIssueOutput
    def self.write(result)
      return unless result

      unless result.kind_of?(Hash) && result.key?(:number) && result.key?(:url)
        puts("Warning: tracking issue result was malformed; skipping tracking issue outputs")
        return
      end

      number = result[:number]
      url = result[:url]
      return if number.to_s.empty? || url.to_s.empty?

      output_path = WorkflowCommand.env_value("GITHUB_OUTPUT")
      return unless output_path

      File.open(output_path, "a") { |file|
        file.puts("tracking-issue-number=#{number}")
        file.puts("tracking-issue-url=#{url}")
      }
    end
  end

  # Normalizes one legacy warning string plus optional structured detail.
  class WarningRecord
    def self.build(warnings, details)
      Array(warnings).map.with_index { |warning, index| new(warning, details[index]).to_h }
    end

    def self.parse(warning)
      message, source = warning.to_s.split("\nSource: ", 2)
      record = { "message" => message }
      record["source"] = source unless source.to_s.empty?
      record
    end

    def initialize(warning, detail)
      @warning = warning
      @detail = detail
      @record = {}
    end

    def to_h
      @record = parsed_warning.merge(string_keyed_detail)
      normalize_message
    end

    private

    def normalize_message
      parsed_message = self.class.parse(@record["message"])
      @record.merge(
        "message" => parsed_message["message"],
        "source" => @record["source"] || parsed_message["source"]
      ).compact
    end

    def parsed_warning
      self.class.parse(@warning)
    end

    def string_keyed_detail
      @detail.to_h.transform_keys(&:to_s).compact
    end
  end

  def initialize(warnings, warning_details = nil, parse_warnings = nil, **options)
    @warnings = Array(warnings)
    @warning_details = Array(warning_details)
    @parse_warnings = Array(parse_warnings)
    @missing_resolved = Array(options[:missing_resolved])
    @applied_updates = options[:applied_updates]
    @timings = options[:timings]
  end

  def write
    write_outputs
    write_summary
    emit_annotations
  end

  def write_outputs
    write_action_outputs
  end

  def write_summary
    write_step_summary
  end

  def emit_annotations
    emit_warning_annotations
  end

  def records
    @records ||= warning_records.map { |record| UpdateSeverity.apply(record) }
  end

  def severity_counts
    @severity_counts ||= UpdateSeverity.counts(records)
  end

  private

  def warning_records
    WarningRecord.build(@warnings, @warning_details)
  end

  def write_action_outputs
    output_path = WorkflowCommand.env_value("GITHUB_OUTPUT")
    return unless output_path

    File.open(output_path, "a") { |file|
      file.puts(action_output_lines)
      WorkflowCommand.write_multiline_output(file, "updates-json", JSON.generate(sanitized_records))
      WorkflowCommand.write_multiline_output(file, "applied-updates-json", JSON.generate(applied_update_records))
    }
  end

  def sanitized_records
    records.map { |record| CredentialRedactor.redact_hash_value(record, "repository_url") }
  end

  def write_step_summary
    summary_path = WorkflowCommand.env_value("GITHUB_STEP_SUMMARY")
    return unless summary_path

    File.open(summary_path, "a") { |file| file.puts(step_summary_lines) }
  end

  def action_output_lines
    [
      "updates-found=#{records.size}",
      "major-updates-found=#{severity_counts['major']}",
      "minor-updates-found=#{severity_counts['minor']}",
      "patch-updates-found=#{severity_counts['patch']}",
      "parse-warnings=#{@parse_warnings.size}",
      "missing-resolved=#{@missing_resolved.size}",
      "applied-updates=#{applied_update_records.size}",
      "blocked=false",
      "error-message=",
    ]
  end

  def step_summary_lines
    update_lines = if records.empty?
                     [SUMMARY_HEADING, "", "All SPM dependencies are up to date."]
                   else
                     [SUMMARY_HEADING, "", update_count_line, "", *update_summary_lines]
                   end
    update_lines +
      Render::ParseWarningsSection.new(@parse_warnings).summary_lines +
      Render::MissingResolvedSection.new(@missing_resolved).summary_lines +
      Render::AppliedUpdatesSection.new(@applied_updates).summary_lines +
      timing_summary_lines
  end

  def timing_summary_lines
    @timings ? @timings.summary_lines : []
  end

  def update_count_line
    count = records.size
    update_label = count == 1 ? "update" : "updates"
    "Found **#{count}** potential dependency #{update_label}."
  end

  def update_summary_lines
    records.each.with_index(1).flat_map { |record, index|
      message, source = record.values_at("message", "source")
      lines = ["#{index}. #{message}"]
      lines << "   Source: `#{source}`" if source
      links = summary_links(record)
      lines << "   #{links}" if links
      lines.concat(upgrade_hint_lines(record))
    }
  end

  def upgrade_hint_lines(record)
    command, requirement = record.values_at("suggested_command", "suggested_requirement")
    lines = []
    lines << "   Update: `#{command}`" if command
    lines << "   Manifest: `#{requirement}`" if requirement
    lines
  end

  def summary_links(record)
    Render::VersionLinks.markdown_links(record, separator: " · ")
  end

  def emit_warning_annotations
    records.each { |record|
      source, message = record.values_at("source", "message")
      properties = { "title" => "SPM dependency update" }
      properties["file"] = source if source

      puts(WorkflowCommand.annotation("warning", properties, message))
    }
    emit_parse_warning_annotations
    emit_missing_resolved_annotations
  end

  def emit_parse_warning_annotations
    @parse_warnings.each { |record|
      properties = { "title" => "SPM manifest parse warning", "file" => record["source"] }.compact
      puts(WorkflowCommand.annotation("warning", properties, record["message"]))
    }
  end

  def emit_missing_resolved_annotations
    @missing_resolved.each { |record|
      properties = { "title" => "Missing Package.resolved", "file" => record["source"] }.compact
      puts(WorkflowCommand.annotation("warning", properties, record["message"]))
    }
  end

  def applied_update_records
    return [] unless @applied_updates

    @applied_updates.to_json_records
  end
end
