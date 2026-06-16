# frozen_string_literal: true

require_relative "git_operations"
require_relative "manifest_parser"
require_relative "semver"

# Rewrites supported Package.swift dependency requirements for update records.
module ManifestUpdater
  SUPPORTED_KINDS = %w(exactVersion upToNextMajorVersion upToNextMinorVersion versionRange).freeze

  # Result of rewriting one manifest's dependency declarations.
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

  # Normalized update input used by the private rewrite pipeline.
  class UpdateRecord
    def initialize(attributes)
      @attributes = attributes.to_h.transform_keys(&:to_s)
    end

    def kind
      value("requirement_kind")
    end

    def type
      value("type")
    end

    def normalized_url
      value("normalized_url")
    end

    def available_version
      value("available_version")
    end

    def applied_entry
      @attributes.merge("available_version" => available_version)
    end

    def skipped_entry(reason)
      @attributes.merge("reason" => reason)
    end

    private

    def value(key)
      @attributes[key]
    end
  end
  private_constant :UpdateRecord

  # Collects the rewrite outcome while package declarations are scanned.
  class RewriteChanges
    attr_reader :edits, :applied, :skipped

    def initialize
      @edits = []
      @applied = []
      @skipped = []
    end

    def apply(update, edits)
      @edits.concat(edits)
      @applied << update.applied_entry
    end

    def skip(update, reason)
      @skipped << update.skipped_entry(reason)
    end
  end
  private_constant :RewriteChanges

  # Success or failure from attempting to rewrite one update record.
  RewritePlan = Struct.new(:edits, :reason, keyword_init: true) {
    def self.success(edits)
      new(edits:, reason: nil)
    end

    def self.failure(reason)
      new(edits: [], reason:)
    end

    def failed?
      reason
    end
  }
  private_constant :RewritePlan

  # Computes all declaration edits for one update record.
  class EditPlanner
    def initialize(update, spans)
      @update = update
      @spans = spans
    end

    def plan
      return RewritePlan.failure("declaration_not_found") if matching_spans.empty?

      plan_matching_spans
    end

    private

    attr_reader :update

    def matching_spans
      @matching_spans ||= @spans.select { |span| SpanPackage.new(span).normalized_url == update.normalized_url }
    end

    def plan_matching_spans
      attempts = matching_spans.map { |span| EditAttempt.new(update, span).plan }
      attempts.find(&:failed?) || RewritePlan.success(attempts.flat_map(&:edits))
    end
  end
  private_constant :EditPlanner

  # Package metadata parsed from one declaration span.
  class SpanPackage
    def initialize(span)
      @span = span
    end

    def normalized_url
      GitOperations.trim_repo_url(url.value)
    end

    private

    def url
      UrlLiteral.new(@span.body)
    end
  end
  private_constant :SpanPackage

  # Reads a Package.swift dependency URL literal from one declaration body.
  class UrlLiteral
    def initialize(body)
      @body = body
    end

    def value
      @body[/\burl\s*:\s*"([^"]+)"/, 1]
    end
  end
  private_constant :UrlLiteral

  # Source body checks that determine whether a declaration can be safely edited.
  class DeclarationBody
    def initialize(body)
      @body = body
    end

    def unsupported_syntax?
      @body.include?("\\(") || @body.match?(/#+"/)
    end
  end
  private_constant :DeclarationBody

  # Attempts the single-span edit for one update and returns a rewrite plan.
  class EditAttempt
    def initialize(update, span)
      @update = update
      @span = span
    end

    def plan
      return RewritePlan.failure("unsupported_syntax") if unsupported_syntax?
      return RewritePlan.failure("requirement_mismatch") unless requirement_matches? && edit
      return RewritePlan.failure("verification_failed") unless verifier.verified?

      RewritePlan.success([edit])
    end

    private

    attr_reader :update, :span

    def unsupported_syntax?
      DeclarationBody.new(span.body).unsupported_syntax?
    end

    def requirement_matches?
      requirement && requirement["kind"] == update.kind
    end

    def requirement
      @requirement ||= ManifestParser.requirement_for(span.body)
    end

    def edit
      @edit ||= RequirementEdit.new(update, span).to_h
    end

    def verifier
      EditVerifier.new(update, span, edit)
    end
  end
  private_constant :EditAttempt

  # Builds the byte-range replacement for one supported requirement.
  class RequirementEdit
    def initialize(update, span)
      @update = update
      @span = span
    end

    def to_h
      return unless target && offset

      body_start = span.body_start
      {
        start: body_start + offset[0],
        finish: body_start + offset[1],
        replacement: target
      }
    end

    private

    attr_reader :update, :span

    def target
      @target ||= TargetVersion.new(update, span.body).value
    end

    def offset
      @offset ||= VersionLiteralLocator.new(span.body, update).offset
    end
  end
  private_constant :RequirementEdit

  # Chooses the target version, including range upper-bound expansion.
  class TargetVersion
    def initialize(update, body)
      @update = update
      @body = body
    end

    def value
      return @update.available_version unless expand_range_maximum?

      maximum_for_range
    end

    private

    def expand_range_maximum?
      @update.kind == "versionRange" && @update.type == "above_maximum"
    end

    def maximum_for_range
      available_version = @update.available_version
      return available_version if range.closed?

      version = SpmVersionUpdates::Semver.new(available_version)
      "#{version.major + 1}.0.0"
    rescue ArgumentError
      nil
    end

    def range
      @range ||= VersionRangeLiteral.new(@body)
    end
  end
  private_constant :TargetVersion

  # Locates the version literal that should be replaced inside a declaration.
  class VersionLiteralLocator
    def initialize(body, update)
      @body = body
      @update = update
    end

    def offset
      case @update.kind
      when "exactVersion" then exact_offset
      when "upToNextMajorVersion" then major_offset
      when "upToNextMinorVersion" then minor_offset
      when "versionRange" then range_offset
      end
    end

    private

    def exact_offset
      first_capture([/\bexact\s*:\s*"([^"]+)"/, /\.exact\s*\(\s*"([^"]+)"/])
    end

    def major_offset
      first_capture([/\.upToNextMajor\s*\(\s*from\s*:\s*"([^"]+)"/, /\bfrom\s*:\s*"([^"]+)"/])
    end

    def minor_offset
      first_capture([/\.upToNextMinor\s*\(\s*from\s*:\s*"([^"]+)"/])
    end

    def range
      @range ||= VersionRangeLiteral.new(@body)
    end

    def range_offset
      @update.type == "above_maximum" ? range.maximum_offset : range.minimum_offset
    end

    def first_capture(patterns)
      patterns.each { |pattern|
        match = @body.match(pattern)
        return match.offset(1) if match
      }
      nil
    end
  end
  private_constant :VersionLiteralLocator

  # Parsed Swift range literal for supported version-range requirements.
  class VersionRangeLiteral
    def initialize(body)
      @match = body.match(/"([^"]+)"\s*(\.\.[.<])\s*"([^"]+)"/)
    end

    def closed?
      operator == "..."
    end

    def minimum_offset
      return unless @match

      @match.offset(1)
    end

    def maximum_offset
      return unless @match

      @match.offset(3)
    end

    private

    def operator
      @match&.[](2)
    end
  end
  private_constant :VersionRangeLiteral

  # Verifies a generated edit still parses to the original requirement kind.
  class EditVerifier
    def initialize(update, span, edit)
      @update = update
      @span = span
      @edit = edit
    end

    def verified?
      return false unless edited_requirement_kind == @update.kind

      edited_value == @edit[:replacement]
    end

    private

    def edited_requirement_kind
      ManifestParser.requirement_for(edited_body)&.fetch("kind", nil)
    end

    def edited_value
      offset = VersionLiteralLocator.new(edited_body, @update).offset
      offset && edited_body[offset[0]...offset[1]]
    end

    def edited_body
      @edited_body ||= EditedBody.new(@span, @edit).value
    end
  end
  private_constant :EditVerifier

  # Applies one edit against a declaration body for verification.
  class EditedBody
    def initialize(span, edit)
      @span = span
      @edit = edit
    end

    def value
      @value ||= @span.body.dup.tap { |body| body[relative_range] = @edit[:replacement] }
    end

    private

    def relative_range
      relative_start...relative_finish
    end

    def relative_start
      @edit[:start] - @span.body_start
    end

    def relative_finish
      @edit[:finish] - @span.body_start
    end
  end
  private_constant :EditedBody

  # Applies collected edits from right to left to preserve byte offsets.
  class AppliedEdit
    def initialize(attributes)
      @attributes = attributes
    end

    def start
      @attributes[:start]
    end

    def apply_to(content)
      content[start...@attributes[:finish]] = @attributes[:replacement]
    end
  end
  private_constant :AppliedEdit

  # Applies collected edits from right to left to preserve byte offsets.
  class EditApplier
    def initialize(content, edits)
      @content = content
      @edits = edits.map { |edit| AppliedEdit.new(edit) }
    end

    def content
      @edits.sort_by { |edit| -edit.start }
        .each_with_object(@content.dup) { |edit, updated|
        edit.apply_to(updated)
      }
    end
  end
  private_constant :EditApplier

  # Stateful implementation kept private so the public API remains small.
  class Rewriter
    def initialize(content, updates)
      @content = content
      @updates = Array(updates).map { |update| UpdateRecord.new(update) }
      @spans = ManifestParser.package_call_spans(content)
      @changes = RewriteChanges.new
    end

    def rewrite
      @updates.each { |update| rewrite_update(update) }
      updated_content = EditApplier.new(@content, @changes.edits).content
      Result.new(content: updated_content, applied: @changes.applied, skipped: @changes.skipped, changed: updated_content != @content)
    end

    private

    def rewrite_update(update)
      plan = rewrite_plan(update)
      return @changes.skip(update, plan.reason) if plan.failed?

      @changes.apply(update, plan.edits)
    end

    def rewrite_plan(update)
      return RewritePlan.failure("unsupported_requirement_kind") unless SUPPORTED_KINDS.include?(update.kind)

      EditPlanner.new(update, @spans).plan
    end
  end
  private_constant :Rewriter
end
