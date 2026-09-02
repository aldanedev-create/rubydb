# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Recovery::CorruptionDetector do
  it "does not report unsupported corruption repairs as successful" do
    detector = described_class.new(Object.new)

    result = detector.repair_corruption(issues: [{ type: "page_size", page: 1 }])

    expect(result[:repaired]).to be(false)
    expect(result[:actions].first[:success]).to be(false)
  end

  it "refuses to claim a record repair when no safe default exists" do
    column = RubyDB::Catalog::Column.new("name", :text)
    engine = Object.new
    allow(engine).to receive(:table_columns).with("users").and_return([column])
    allow(engine).to receive(:select_row).with("users", 1, [column]).and_return({ name: "bad" })
    detector = described_class.new(engine)

    result = detector.repair_corruption(
      issues: [{ type: "record_value", table: "users", row: 1, column: "name" }]
    )

    expect(result[:repaired]).to be(false)
    expect(result[:actions].first[:success]).to be(false)
  end
end
