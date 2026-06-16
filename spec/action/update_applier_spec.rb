# frozen_string_literal: true

require_relative "../../action/lib/update_applier"

RSpec.describe UpdateApplier do
  let(:updater) { class_double(ManifestUpdater) }
  let(:record) {
    lambda { |overrides = {}|
      {
        type: "version",
        package: "foo/bar",
        source: "Package.swift",
        current_version: "1.0.0",
        available_version: "1.1.0",
        requirement_kind: "upToNextMajorVersion"
      }.merge(overrides)
    }
  }

  it "groups eligible version records by manifest source", :aggregate_failures do
    applied_records = [record.call, record.call(package: "baz/qux")].map { |entry| entry.transform_keys(&:to_s) }
    result = ManifestUpdater::Result.new(content: "", applied: applied_records, skipped: [], changed: true)
    allow(updater).to receive(:update_file).and_return(result)

    applied = described_class.new([record.call, record.call(package: "baz/qux")], updater:).apply

    expect(updater).to have_received(:update_file).with("Package.swift", array_including(a_hash_including("package" => "foo/bar"), a_hash_including("package" => "baz/qux")))
    expect(applied.applied_count).to eq(2)
  end

  it "classifies ineligible records as skipped", :aggregate_failures do
    allow(updater).to receive(:update_file)

    result = described_class.new(
      [
        record.call(type: "above_maximum"),
        record.call(type: "revision"),
        record.call(source: nil),
      ],
      updater:
    ).apply

    expect(result.skipped.map { |entry| entry["reason"] }).to contain_exactly("above-maximum", "revision", "no-source")
    expect(updater).not_to have_received(:update_file)
  end

  it "records per-file failures and continues", :aggregate_failures do
    allow(updater).to receive(:update_file).and_raise(StandardError, "boom")

    result = described_class.new([record.call], updater:).apply

    expect(result.failed).to eq([{ source: "Package.swift", error: "boom" }])
    expect(result).to be_failed
  end
end
