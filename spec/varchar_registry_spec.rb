# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Types::TypeRegistry do
  it "provides a production default limit for unqualified VARCHAR columns" do
    type = described_class.lookup(:varchar)

    expect(type.limit).to eq(255)
    expect(type.serialize("adapter value")).to eq("adapter value")
  end

  it "preserves an explicit VARCHAR limit" do
    expect(described_class.lookup(:varchar, limit: 3).limit).to eq(3)
  end
end
