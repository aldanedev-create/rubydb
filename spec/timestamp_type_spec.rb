# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Types::Timestamp do
  it "serializes ISO-8601 strings produced by Rails" do
    bytes = described_class.new.serialize("2026-09-09T11:18:08Z")

    expect(described_class.new.deserialize(bytes)).to be_within(1).of(Time.parse("2026-09-09T11:18:08Z"))
  end
end
