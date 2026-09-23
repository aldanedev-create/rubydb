# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Accelerator::Manager do
  it "supports per-workload thresholds without enabling an unavailable worker" do
    manager = described_class.new(
      mode: "auto",
      binary: File.join(Dir.tmpdir, "rubydb-missing-worker"),
      min_rows: 100,
      min_rows_by_workload: {scan: 1_000, join: 5_000}
    )

    expect(manager.min_rows_for(:scan)).to eq(1_000)
    expect(manager.min_rows_for(:join)).to eq(5_000)
    expect(manager.min_rows_for(:aggregate)).to eq(100)
    expect(manager.accelerator_policy(:scan, input_rows: 10_000)).to be(false)
  end

  it "rejects invalid workload threshold configuration" do
    expect do
      described_class.new(mode: "off", min_rows_by_workload: {scan: -1})
    end.to raise_error(RubyDB::Accelerator::Error, /minimum rows/i)
  end
end
