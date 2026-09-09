# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Storage::Deserializer do
  it "preserves a stored false value when the column default is true" do
    columns = [RubyDB::Catalog::Column.new(:active, :boolean, default: true, null: false)]
    row = RubyDB::Storage::Row.new(1, columns, active: false)
    data = RubyDB::Storage::Serializer.serialize_row(row, columns, null_bitmap: true)

    expect(described_class.deserialize_row(data, columns, null_bitmap: true)[:active]).to be(false)
  end

  it "raises a typed corruption error for a truncated variable-length field" do
    columns = [RubyDB::Catalog::Column.new(:name, :varchar, null: false)]
    data = [10].pack("N") + "x"

    expect do
      described_class.deserialize_row(data, columns, variable_length_prefixes: true)
    end.to raise_error(RubyDB::CorruptionError, /name/)
  end
end
