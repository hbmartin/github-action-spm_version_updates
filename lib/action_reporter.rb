# frozen_string_literal: true

require "json"
require_relative "update_severity"

# Writes GitHub Actions-visible reports for the dependency update results.
class ActionReporter
  # Shared GitHub Actions output and annotation formatting.
  module WorkflowCommand
    module_function

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
        "## SPM Version Updates",
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
    @records ||= detail_records.map { |record| UpdateSeverity.apply(record) }
  end

  def severity_counts
    @severity_counts ||= UpdateSeverity.counts(records)
  end

  private

  def warning_records
    @warnings.map { |warning| parsed_warning_record(warning) }
  end

  def detail_records
    warning_records.map.with_index { |fallback, index|
      record = fallback.dup
      detail = @warning_details[index]
      detail&.each_with_object(record) { |(key, value), result|
        result[key.to_s] = value unless value.nil?
      }

      parsed_message = parsed_warning_record(record["message"])
      record["message"] = parsed_message["message"]
      parsed_source = parsed_message["source"]
      record["source"] ||= parsed_source if parsed_source
      record
    }
  end

  def parsed_warning_record(warning)
    message, source = warning.to_s.split("\nSource: ", 2)
    record = { "message" => message }
    record["source"] = source unless source.nil? || source.empty?
    record
  end

  def write_action_outputs
    output_path = WorkflowCommand.env_value("GITHUB_OUTPUT")
    return unless output_path

    File.open(output_path, "a") { |file|
      file.puts(action_output_lines)
      WorkflowCommand.write_multiline_output(file, "updates-json", JSON.generate(records))
    }
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
    return ["## SPM Version Updates", "", "All SPM dependencies are up to date."] if records.empty?

    ["## SPM Version Updates", "", update_count_line, "", *update_summary_lines]
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
      lines
    }
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
