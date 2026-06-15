# frozen_string_literal: true

require_relative "git_operations"
require_relative "manifest_parser"
require_relative "semver"

# Rewrites supported Package.swift dependency requirements for update records.
module ManifestUpdater
  SUPPORTED_KINDS = %w(exactVersion upToNextMajorVersion upToNextMinorVersion versionRange).freeze

  Result = Struct.new(:content, :applied, :skipped, :changed, keyword_init: true) {
    def changed?
      changed
    end
  }

  def self.rewrite(content, updates)
    Rewriter.new(content, updates).rewrite
  end

  def self.update_file(manifest_path, updates)
    original = File.read(manifest_path)
    result = rewrite(original, updates)
    File.write(manifest_path, result.content) if result.changed?
    result
  end

  # Stateful implementation kept private so the public API remains small.
  class Rewriter
    def initialize(content, updates)
      @content = content
      @updates = Array(updates)
      @spans = ManifestParser.package_call_spans(content)
      @edits = []
      @applied = []
      @skipped = []
    end

    def rewrite
      @updates.each { |update| rewrite_update(update) }
      updated_content = apply_edits
      Result.new(content: updated_content, applied: @applied, skipped: @skipped, changed: updated_content != @content)
    end

    private

    def rewrite_update(update)
      kind = value(update, "requirement_kind")
      return skip(update, "unsupported_requirement_kind") unless SUPPORTED_KINDS.include?(kind)

      matches = matching_spans(value(update, "normalized_url"))
      return skip(update, "declaration_not_found") if matches.empty?

      edits, reason = edits_for(update, matches, kind)
      return skip(update, reason) if reason

      @edits.concat(edits)
      @applied << applied_entry(update)
    end

    def matching_spans(normalized_url)
      @spans.select { |span| GitOperations.trim_repo_url(url_for(span.body)) == normalized_url }
    end

    def url_for(body)
      body[/\burl\s*:\s*"([^"]+)"/, 1]
    end

    def edits_for(update, matches, kind)
      edits = []
      matches.each { |span|
        edit, reason = edit_or_failure(update, span, kind)
        return [[], reason] if reason

        edits << edit
      }
      [edits, nil]
    end

    def edit_or_failure(update, span, kind)
      return [nil, "unsupported_syntax"] if unsupported_syntax?(span.body)

      requirement = ManifestParser.requirement_for(span.body)
      return [nil, "requirement_mismatch"] unless requirement && requirement["kind"] == kind

      edit = edit_for(update, span, requirement)
      return [nil, "requirement_mismatch"] unless edit
      return [nil, "verification_failed"] unless verified_edit?(span, edit, kind, value(update, "type"))

      [edit, nil]
    end

    def unsupported_syntax?(body)
      body.include?("\\(") || body.match?(/#+"/)
    end

    def edit_for(update, span, requirement)
      target = target_version(update, span.body, requirement["kind"])
      offset = literal_offset(span.body, requirement["kind"], value(update, "type"))
      return unless target && offset

      {
        start: span.body_start + offset[0],
        finish: span.body_start + offset[1],
        replacement: target
      }
    end

    def target_version(update, body, kind)
      available = value(update, "available_version")
      return available unless kind == "versionRange" && value(update, "type") == "above_maximum"

      maximum_for_range(available, body)
    end

    def maximum_for_range(available, body)
      return available if range_operator(body) == "..."

      version = SpmVersionUpdates::Semver.new(available)
      "#{version.major + 1}.0.0"
    rescue ArgumentError
      nil
    end

    def range_operator(body)
      body.match(/"[^"]+"\s*(\.\.[.<])\s*"[^"]+"/)&.[](1)
    end

    def literal_offset(body, kind, type)
      case kind
      when "exactVersion" then first_capture(body, [/\bexact\s*:\s*"([^"]+)"/, /\.exact\s*\(\s*"([^"]+)"/])
      when "upToNextMajorVersion" then first_capture(body, [/\.upToNextMajor\s*\(\s*from\s*:\s*"([^"]+)"/, /\bfrom\s*:\s*"([^"]+)"/])
      when "upToNextMinorVersion" then first_capture(body, [/\.upToNextMinor\s*\(\s*from\s*:\s*"([^"]+)"/])
      when "versionRange" then range_capture(body, type)
      end
    end

    def range_capture(body, type)
      match = body.match(/"([^"]+)"\s*(\.\.[.<])\s*"([^"]+)"/)
      return unless match

      match.offset(type == "above_maximum" ? 3 : 1)
    end

    def first_capture(body, patterns)
      patterns.each { |pattern|
        match = body.match(pattern)
        return match.offset(1) if match
      }
      nil
    end

    def verified_edit?(span, edit, kind, type)
      edited = span.body.dup
      relative_start = edit[:start] - span.body_start
      relative_finish = edit[:finish] - span.body_start
      edited[relative_start...relative_finish] = edit[:replacement]
      return false unless ManifestParser.requirement_for(edited)&.fetch("kind", nil) == kind

      offset = literal_offset(edited, kind, type)
      offset && edited[offset[0]...offset[1]] == edit[:replacement]
    end

    def apply_edits
      @edits.sort_by { |edit| -edit[:start] }
        .each_with_object(@content.dup) { |edit, updated|
        updated[edit[:start]...edit[:finish]] = edit[:replacement]
      }
    end

    def applied_entry(update)
      update.to_h.merge("available_version" => value(update, "available_version"))
    end

    def skip(update, reason)
      @skipped << update.to_h.merge("reason" => reason)
      nil
    end

    def value(hash, key)
      hash[key] || hash[key.to_sym]
    end
  end
  private_constant :Rewriter
end
