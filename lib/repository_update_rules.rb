# frozen_string_literal: true

require "yaml"
require_relative "git_operations"
require_relative "spm_version_updates/semver"
require_relative "update_severity"

# Loads and evaluates per-repository semantic update suppression rules.
class RepositoryUpdateRules
  SEMANTIC_TYPES = ["version", "above_maximum"].freeze
  ALLOWED_UPDATES = ["patch", "minor", "major"].freeze
  SEVERITY_RANK = {
    "patch" => 0,
    "minor" => 1,
    "major" => 2
  }.freeze
  ROOT_KEYS = ["repositories"].freeze
  ENTRY_KEYS = ["url", "ignore-until", "allowed-updates"].freeze

  Rule = Struct.new(:normalized_url, :ignore_until, :allowed_updates, keyword_init: true) {
    def suppressed?(record)
      return true if suppress_until_version?(record)
      return true if suppress_disallowed_severity?(record)

      false
    end

    private

    def suppress_until_version?(record)
      return false unless ignore_until

      available = RepositoryUpdateRules.semver(record_value(record, "available_version"))
      available && available < ignore_until
    end

    def suppress_disallowed_severity?(record)
      return false unless allowed_updates

      severity = UpdateSeverity.for_versions(
        record_value(record, "current_version"),
        record_value(record, "available_version")
      )
      severity && SEVERITY_RANK.fetch(severity) > SEVERITY_RANK.fetch(allowed_updates)
    end

    def record_value(record, key)
      record[key] || record[key.to_sym]
    end
  }
  private_constant :Rule

  def self.empty
    new({})
  end

  def self.load_file(path)
    path = path.to_s.strip
    raise(ArgumentError, "repo-rules-path was set but no file path was provided") if path.empty?
    raise(ArgumentError, "repo-rules-path file does not exist: #{path}") unless File.file?(path)

    from_hash(YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false), source: path)
  rescue Psych::Exception => error
    raise(ArgumentError, "repo-rules YAML is invalid in #{path}: #{error.message}")
  end

  def self.from_hash(config = nil, source: "repo rules", **keyword_config)
    config = keyword_config if config.nil? && !keyword_config.empty?
    raise(ArgumentError, "#{source} must contain a YAML mapping") unless config.kind_of?(Hash)

    string_keys = config.transform_keys(&:to_s)
    validate_keys!(string_keys, ROOT_KEYS, "#{source} root")
    repositories = string_keys["repositories"]
    raise(ArgumentError, "#{source} repositories must be a list") unless repositories.kind_of?(Array)

    new(parse_repositories(repositories, source))
  end

  def self.semver(value)
    SpmVersionUpdates::Semver.new(value.to_s)
  rescue ArgumentError
    nil
  end

  def self.parse_repositories(repositories, source)
    repositories.each_with_object({}).with_index(1) { |(entry, rules), index|
      rule = parse_entry(entry, "#{source} repositories[#{index}]")
      raise(ArgumentError, "duplicate repo-rules entry for #{rule.normalized_url}") if rules.key?(rule.normalized_url)

      rules[rule.normalized_url] = rule
    }
  end

  def self.parse_entry(entry, source)
    raise(ArgumentError, "#{source} must be a mapping") unless entry.kind_of?(Hash)

    string_keys = entry.transform_keys(&:to_s)
    validate_keys!(string_keys, ENTRY_KEYS, source)

    normalized_url = normalized_url_for(required_value(string_keys, "url", source))
    ignore_until = parse_ignore_until(string_keys, source)
    allowed_updates = parse_allowed_updates(string_keys, source)
    raise(ArgumentError, "#{source} must set ignore-until or allowed-updates") unless ignore_until || allowed_updates

    Rule.new(normalized_url:, ignore_until:, allowed_updates:)
  end

  def self.validate_keys!(values, allowed, source)
    unknown = values.keys - allowed
    return if unknown.empty?

    raise(ArgumentError, "#{source} contains unknown key(s): #{unknown.join(', ')}")
  end

  def self.required_value(values, key, source)
    value = values[key].to_s.strip
    raise(ArgumentError, "#{source} #{key} must be set") if value.empty?

    value
  end

  def self.normalized_url_for(value)
    normalized = GitOperations.trim_repo_url(value)
    raise(ArgumentError, "repo-rules url must normalize to a repository URL") if normalized.empty?

    normalized
  end

  def self.parse_ignore_until(values, source)
    return unless values.key?("ignore-until")

    raw = values["ignore-until"].to_s.strip
    version = semver(raw)
    raise(ArgumentError, "#{source} ignore-until must be a semantic version") unless version

    version
  end

  def self.parse_allowed_updates(values, source)
    return unless values.key?("allowed-updates")

    value = values["allowed-updates"].to_s.strip.downcase
    return value if ALLOWED_UPDATES.include?(value)

    raise(ArgumentError, "#{source} allowed-updates must be patch, minor, or major")
  end

  private_class_method(
    :parse_repositories,
    :parse_entry,
    :validate_keys!,
    :required_value,
    :normalized_url_for,
    :parse_ignore_until,
    :parse_allowed_updates
  )

  def initialize(rules_by_repo)
    @rules_by_repo = rules_by_repo
  end

  def empty?
    @rules_by_repo.empty?
  end

  def suppressed?(record)
    return false unless semantic_record?(record)

    rule = @rules_by_repo[normalized_record_url(record)]
    rule ? rule.suppressed?(record) : false
  end

  private

  def semantic_record?(record)
    SEMANTIC_TYPES.include?(record_value(record, "type").to_s)
  end

  def normalized_record_url(record)
    GitOperations.trim_repo_url(record_value(record, "normalized_url") || record_value(record, "repository_url"))
  end

  def record_value(record, key)
    record[key] || record[key.to_sym]
  end
end
