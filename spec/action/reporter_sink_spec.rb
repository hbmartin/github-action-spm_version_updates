# frozen_string_literal: true

require_relative "../../action/lib/reporter_sink"

RSpec.describe(ReporterSink) {
  subject(:sink) { described_class.new }

  it("defines the clean-run report message") do
    expect(described_class::SUCCESS_MESSAGE).to(eq("✅ **SPM Dependencies**: All dependencies are up to date!"))
  end

  it("requires concrete sinks to publish update reports") do
    expect { sink.publish_updates(["warning"]) }
      .to(raise_error(NotImplementedError, "ReporterSink must implement #publish_updates"))
  end

  it("requires concrete sinks to publish clean-run reports") do
    expect { sink.publish_success }
      .to(raise_error(NotImplementedError, "ReporterSink must implement #publish_success"))
  end

  it("requires concrete sinks to clear stale reports") do
    expect { sink.clear }
      .to(raise_error(NotImplementedError, "ReporterSink must implement #clear"))
  end
}
