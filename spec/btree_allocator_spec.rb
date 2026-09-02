# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Indexes::BTree do
  it "allocates unique node pages through the owning tree" do
    index = described_class.new("events_id", "events", [:id], order: 3)
    50.times { |id| index.insert(id, id + 100) }

    expect(index.validate).to be(true)
    expect(index.search(37)).to eq(137)
    expect(index.range_search(10, 14).map { |entry| entry[:value] }).to eq([110, 111, 112, 113, 114])
    expect(index.analyze[:nodes]).to be > 1
  end
end
