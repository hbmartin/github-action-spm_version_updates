# frozen_string_literal: true

require "uri"
require_relative "credential_redactor"

# Builds the structured records used to report `.package(...)` declarations
# that the manifest parser had to skip, plus the pre-filled GitHub issue link
# shown alongside them. The manifest snippet is redacted and shown in the
# report only — never embedded in the issue URL, where it could leak private
# repository URLs through logs or referrer headers.
module ParseWarning
  ISSUE_URL = "https://github.com/hbmartin/github-action-spm_version_updates/issues/new"
  SNIPPET_LIMIT = 200

  REASONS = {
    "unrecognized_requirement" => "its version requirement was not recognized",
    "unbalanced_parentheses" => "it has unbalanced parentheses, so the remainder of this manifest was not scanned"
  }.freeze

  # @param reason [String] a REASONS key
  # @param source [String] the manifest path the declaration came from
  # @param snippet [String] the raw declaration text (redacted and truncated here)
  # @return [Hash] type / reason / source / snippet / message, string-keyed
  def self.record(reason:, source:, snippet:)
    reason = reason.to_s
    {
      "type" => "parse_warning",
      "reason" => reason,
      "source" => source,
      "snippet" => truncated_snippet(snippet),
      "message" => message_for(reason, source)
    }
  end

  # A GitHub new-issue URL pre-filled with everything except the manifest
  # content, which the template asks the reporter to paste in themselves.
  # @param record [Hash] a {record} hash
  # @return [String]
  def self.issue_link(record)
    reason = record["reason"]
    query = URI.encode_www_form(
      title: "Manifest parse failure: #{reason}",
      body: issue_body(reason)
    )
    "#{ISSUE_URL}?#{query}"
  end

  # @param record [Hash] a {record} hash
  # @return [String] the reason as a readable phrase
  def self.describe_reason(record)
    reason = record["reason"]
    REASONS.fetch(reason, reason)
  end

  def self.message_for(reason, source)
    "Could not parse a `.package(...)` declaration in #{source} because " \
      "#{REASONS.fetch(reason, reason)}. Updates for the affected " \
      "dependency were not checked. If this is valid Swift, please open an issue."
  end

  def self.truncated_snippet(snippet)
    redacted = CredentialRedactor.redact(snippet.to_s.strip).to_s
    return redacted if redacted.length <= SNIPPET_LIMIT

    "#{redacted[0, SNIPPET_LIMIT]}…"
  end

  def self.issue_body(reason)
    <<~BODY
      A `.package(...)` declaration in my `Package.swift` could not be parsed (reason: #{reason}).

      Please paste the declaration below (remove any credentials or private URLs first):

      ```swift
      (paste the .package(...) declaration here)
      ```
    BODY
  end

  private_class_method :message_for, :truncated_snippet, :issue_body
end
