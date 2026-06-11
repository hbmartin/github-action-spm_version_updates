# frozen_string_literal: true

require "json"
require_relative "credential_redactor"
require_relative "repository_link"
require_relative "update_severity"

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
      file.puts(OUTPUT_LINES)
      WorkflowCommand.write_multiline_output(file, "error-message", message)
      WorkflowCommand.write_multiline_output(file, "updates-json", JSON.generate([]))
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

  def initialize(warnings, warning_details = nil)
    @warnings = Array(warnings)
    @warning_details = Array(warning_details)
  end

  def write
    write_action_outputs
    write_step_summary
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
      "blocked=false",
      "error-message=",
    ]
  end

  def step_summary_lines
    return [SUMMARY_HEADING, "", "All SPM dependencies are up to date."] if records.empty?

    [SUMMARY_HEADING, "", update_count_line, "", *update_summary_lines]
  end

  def update_count_line
    count = records.size
    "Found **#{count}** potential dependency update#{count == 1 ? '' : 's'}."
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
    link = RepositoryLink.from(record["repository_url"])
    return unless link

    current, available = record.values_at("current_version", "available_version")
    return unless current && available

    link.markdown_links([{ current:, available: }], separator: " · ")
  end

  def emit_warning_annotations
    records.each { |record|
      source, message = record.values_at("source", "message")
      properties = { "title" => "SPM dependency update" }
      properties["file"] = source if source

      puts(WorkflowCommand.annotation("warning", properties, message))
    }
  end
end
