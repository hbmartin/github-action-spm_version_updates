# frozen_string_literal: true

# Collects monotonic elapsed timings for the GitHub Actions step summary.
class Timings
  def initialize(clock: Process)
    @clock = clock
    @starts = {}
    @elapsed = {}
  end

  def start(phase)
    @starts[phase] = now
  end

  def finish(phase)
    started = @starts.delete(phase)
    return unless started

    @elapsed[phase] = now - started
  end

  def measure(phase)
    started = now
    yield
  ensure
    @elapsed[phase] = now - started
  end

  def summary_lines
    return [] if @elapsed.empty?

    ["", "### Timings", "", "| Phase | Duration |", "| --- | --- |"] +
      @elapsed.map { |phase, seconds| "| #{phase} | #{format('%.1fs', seconds)} |" }
  end

  private

  def now
    @clock.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
