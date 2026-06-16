# frozen_string_literal: true

require_relative "../../action/lib/timings"

RSpec.describe Timings do
  let(:fake_clock) {
    lambda { |values|
      remaining = values.dup
      Object.new.tap { |clock|
        clock.define_singleton_method(:clock_gettime) { |_clock_id| remaining.shift }
      }
    }
  }

  it "measures phases and renders a summary table" do
    timings = described_class.new(clock: fake_clock.call([10.0, 11.25]))

    timings.measure("Checks") { "done" }

    expect(timings.summary_lines).to include("| Checks | 1.2s |")
  end

  it "records explicit start and finish phases" do
    timings = described_class.new(clock: fake_clock.call([1.0, 3.0]))

    timings.start("Total")
    timings.finish("Total")

    expect(timings.summary_lines).to include("| Total | 2.0s |")
  end
end
