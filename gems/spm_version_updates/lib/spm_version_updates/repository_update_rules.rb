# frozen_string_literal: true

require "yaml"
require_relative "git_operations"
require_relative "semver"
require_relative "update_severity"

# Loads and evaluates per-repository semantic update suppression rules.
class RepositoryUpdateRules
  SEMANTIC_TYPES = ["version", "above_maximum"].freeze
  SEVERITY_RANK = {
    "patch" => 0,
    "minor" => 1,
    "major" => 2
  }.freeze
  YAML_KEYS = {
    repositories: "repositories",
    url: "url",
    ignore_until: "ignore-until",
    allowed_updates: "allowed-updates"
  }.freeze
  VALID_YAML_KEYS = {
    root: [YAML_KEYS.fetch(:repositories)],
    entry: YAML_KEYS.values_at(:url, :ignore_until, :allowed_updates)
  }.freeze

  # One normalized repository rule from repo-rules YAML.
  Rule = Struct.new(:normalized_url, :ignore_until, :allowed_updates, keyword_init: true) {
    def suppressed?(record)
      return true if suppress_until_version?(record)
      return true if suppress_disallowed_severity?(record)

      false
    end

    private

    def suppress_until_version?(record)
      return false unless ignore_until

      available = RepositoryUpdateRules.semver(RepositoryUpdateRules.record_value(record, "available_version"))
      available && available < ignore_until
    end

    def suppress_disallowed_severity?(record)
      return false unless allowed_updates

      severity = UpdateSeverity.for_versions(
        RepositoryUpdateRules.record_value(record, "current_version"),
        RepositoryUpdateRules.record_value(record, "available_version")
      )
      severity && SEVERITY_RANK.fetch(severity) > SEVERITY_RANK.fetch(allowed_updates)
    end
  }
  private_constant :Rule

  def self.empty
    new({})
  end

  def self.load_file(path)
    path = validated_file_path(path)
    yaml_config = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false) || {}
    from_hash(yaml_config, source: path)
  rescue Psych::Exception => error
    raise(ArgumentError, "repo-rules YAML is invalid in #{path}: #{error.message}")
  end

  def self.from_hash(config = {}, source: "repo rules", **keyword_config)
    effective_config = keyword_config.empty? ? config : keyword_config
    effective_config ||= {}
    raise(ArgumentError, "#{source} must contain a YAML mapping") unless effective_config.kind_of?(Hash)

    new(parse_repositories(repositories_from(effective_config, source), source))
  end

  def self.semver(value)
    SpmVersionUpdates::Semver.new(value.to_s)
  rescue ArgumentError
    nil
  end

  def self.parse_repositories(repositories, source)
    repositories.each_with_object({}).with_index(1) { |(entry, rules), index|
      rule = parse_entry(entry, "#{source} repositories[#{index}]")
      normalized_url = rule.normalized_url
      raise(ArgumentError, "duplicate repo-rules entry for #{normalized_url}") if rules.key?(normalized_url)

      rules[normalized_url] = rule
    }
  end

  def self.parse_entry(entry, source)
    string_keys = rule_entry_from(entry, source)
    rule = rule_attributes(string_keys, source)

    Rule.new(**rule)
  end

  def self.validated_file_path(path)
    path = path.to_s.strip
    raise(ArgumentError, "repo-rules-path was set but no file path was provided") if path.empty?
    raise(ArgumentError, "repo-rules-path file does not exist: #{path}") unless File.file?(path)

    path
  end

  def self.repositories_from(config, source)
    string_keys = config.transform_keys(&:to_s)
    validate_keys!(string_keys, VALID_YAML_KEYS.fetch(:root), "#{source} root")
    repositories = string_keys.compact.fetch(yaml_key(:repositories), [])
    raise(ArgumentError, "#{source} repositories must be a list") unless repositories.kind_of?(Array)

    repositories
  end

  def self.rule_entry_from(entry, source)
    raise(ArgumentError, "#{source} must be a mapping") unless entry.kind_of?(Hash)

    entry.transform_keys(&:to_s).tap { |string_keys| validate_keys!(string_keys, VALID_YAML_KEYS.fetch(:entry), source) }
  end

  def self.rule_attributes(string_keys, source)
    normalized_url = normalized_url_for(required_value(string_keys, yaml_key(:url), source))
    ignore_until = parse_ignore_until(string_keys, source)
    allowed_updates = parse_allowed_updates(string_keys, source)
    raise(ArgumentError, "#{source} must set #{yaml_key(:ignore_until)} or #{yaml_key(:allowed_updates)}") unless ignore_until || allowed_updates

    { normalized_url:, ignore_until:, allowed_updates: }
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
    key = yaml_key(:ignore_until)
    return unless values.key?(key)

    semver(values[key].to_s.strip).tap { |version|
      raise(ArgumentError, "#{source} #{key} must be a semantic version") unless version
    }
  end

  def self.parse_allowed_updates(values, source)
    key = yaml_key(:allowed_updates)
    return unless values.key?(key)

    value = values[key].to_s.strip.downcase
    return value if SEVERITY_RANK.key?(value)

    raise(ArgumentError, "#{source} #{key} must be patch, minor, or major")
  end

  def self.record_value(record, key)
    record[key] || record[key.to_sym]
  end

  def self.yaml_key(name)
    YAML_KEYS.fetch(name)
  end

  private_class_method(
    :parse_repositories,
    :parse_entry,
    :validated_file_path,
    :repositories_from,
    :rule_entry_from,
    :rule_attributes,
    :validate_keys!,
    :required_value,
    :normalized_url_for,
    :parse_ignore_until,
    :parse_allowed_updates,
    :yaml_key
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
    SEMANTIC_TYPES.include?(self.class.record_value(record, "type").to_s)
  end

  def normalized_record_url(record)
    rules = self.class
    GitOperations.trim_repo_url(
      rules.record_value(record, "normalized_url") || rules.record_value(record, "repository_url")
    )
  end
end
