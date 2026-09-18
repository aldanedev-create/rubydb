# frozen_string_literal: true

RSpec.describe RubyDB::Client::Result do
  it "preserves insert identifiers for remote ActiveRecord consumers" do
    result = described_class.new(
      row_id: 7,
      inserted_id: 42,
      affected_rows: 1,
      command_tag: "INSERT 1"
    )

    expect(result.row_id).to eq(7)
    expect(result.inserted_id).to eq(42)
    expect(result.to_hash).to include(row_id: 7, inserted_id: 42)
  end
end
