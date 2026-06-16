# frozen_string_literal: true

require_relative "../../action/lib/report_payload"

RSpec.describe(ReportPayload) do
  it("normalizes structured records to string-keyed hashes", :aggregate_failures) do
    payload = described_class.new(
      updates: [{ message: "Newer version of owner/repo: 2.0.0", source: nil }],
      parse_warnings: [{ message: "Could not parse", source: "Package.swift" }],
      missing_resolved: [{ source: "Package.resolved" }]
    )

    expect(payload.updates).to(eq([{ "message" => "Newer version of owner/repo: 2.0.0" }]))
    expect(payload.parse_warnings).to(eq([{ "message" => "Could not parse", "source" => "Package.swift" }]))
    expect(payload.missing_resolved).to(eq([{ "source" => "Package.resolved" }]))
  end

  it("rejects the removed legacy warning fields") do
    expect { described_class.new(warnings: ["Newer version of owner/repo: 2.0.0"]) }
      .to(raise_error(ArgumentError, /missing keyword: :updates|unknown keyword: :warnings/))
  end
end
