# frozen_string_literal: true

require "json"
require_relative "update_severity"

# Writes GitHub Actions-visible reports for the dependency update results.
class ActionReporter
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
    output_path = env_value("GITHUB_OUTPUT")
    return unless output_path

    updates_json = JSON.generate(records)

    File.open(output_path, "a") { |file|
      file.puts("updates-found=#{records.size}")
      file.puts("major-updates-found=#{severity_counts['major']}")
      file.puts("minor-updates-found=#{severity_counts['minor']}")
      file.puts("patch-updates-found=#{severity_counts['patch']}")
      write_multiline_output(file, "updates-json", updates_json)
    }
  end

  def write_multiline_output(file, name, value)
    delimiter = "SPM_VERSION_UPDATES_JSON"
    delimiter = "#{delimiter}_END" while value.include?(delimiter)

    file.puts("#{name}<<#{delimiter}")
    file.puts(value)
    file.puts(delimiter)
  end

  def write_step_summary
    summary_path = env_value("GITHUB_STEP_SUMMARY")
    return unless summary_path

    File.open(summary_path, "a") { |file|
      file.puts("## SPM Version Updates")
      file.puts

      if records.empty?
        file.puts("All SPM dependencies are up to date.")
      else
        write_update_summary(file)
      end
    }
  end

  def write_update_summary(file)
    file.puts("Found **#{records.size}** potential dependency update#{records.size == 1 ? '' : 's'}.")
    file.puts

    records.each.with_index(1) { |record, index|
      file.puts("#{index}. #{record['message']}")
      file.puts("   Source: `#{record['source']}`") if record["source"]
    }
  end

  def emit_warning_annotations
    records.each { |record|
      properties = { "title" => "SPM dependency update" }
      properties["file"] = record["source"] if record["source"]
      property_string = properties
        .map { |key, value| "#{key}=#{escape_workflow_property(value)}" }
        .join(",")

      puts("::warning #{property_string}::#{escape_workflow_data(record['message'])}")
    }
  end

  def escape_workflow_data(value)
    value.to_s.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
  end

  def escape_workflow_property(value)
    escape_workflow_data(value).gsub(":", "%3A").gsub(",", "%2C")
  end

  def env_value(key)
    value = ENV.fetch(key, nil)
    value.nil? || value.strip.empty? ? nil : value.strip
  end
end
