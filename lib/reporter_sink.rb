# frozen_string_literal: true

# Interface for optional external report destinations, such as PR/MR comments.
class ReporterSink
  SUCCESS_MESSAGE = "✅ **SPM Dependencies**: All dependencies are up to date!"

  # Accepts per-run reporter configuration read from the action inputs. Sinks
  # that need no configuration ignore it.
  def configure(_inputs); end

  # The tracking issue created or updated by the last publish, as
  # `{ number:, url: }`. Nil for sinks without tracking-issue support or when
  # no issue was touched.
  def tracking_issue_result; end

  def publish_updates(_warnings, _warning_details = nil)
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
