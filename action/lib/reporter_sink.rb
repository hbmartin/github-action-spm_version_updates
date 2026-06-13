# frozen_string_literal: true

# Interface for optional external report destinations, such as PR/MR comments.
class ReporterSink
  SUCCESS_MESSAGE = "✅ **SPM Dependencies**: All dependencies are up to date!"

  # Optional hook for per-run reporter configuration read from action inputs.
  def configure(_inputs)
    # Intentionally no-op; subclasses override when they need configuration.
  end

  # The tracking issue created or updated by the last publish, as
  # `{ number:, url: }`. Nil for sinks without tracking-issue support or when
  # no issue was touched.
  def tracking_issue_result
    # Intentionally no-op; subclasses override when they expose issue metadata.
  end

  # True when this run reports via a tracking issue rather than a PR comment,
  # so publishing must happen even when PR commenting is disabled.
  def tracking_issue_run?
    false
  end

  def publish_updates(_warnings, _warning_details = nil, _parse_warnings = nil, _missing_resolved = nil)
    raise_not_implemented(:publish_updates)
  end

  def publish_success
    raise_not_implemented(:publish_success)
  end

  def clear
    raise_not_implemented(:clear)
  end

  private

  def raise_not_implemented(method_name)
    raise(NotImplementedError, "#{self.class} must implement ##{method_name}")
  end
end
