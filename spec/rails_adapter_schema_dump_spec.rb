# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Rails::Adapter do
  it "preserves primary keys and non-nil schema defaults in dumps" do
    adapter = RubyDB::Rails::Adapter.allocate
    adapter.define_singleton_method(:tables) { ["users"] }
    adapter.define_singleton_method(:columns) do |_table|
      [
        { name: "id", type: :integer, primary_key: true, null: false, default: nil },
        { name: "active", type: :boolean, primary_key: false, null: false, default: false }
      ]
    end
    adapter.define_singleton_method(:quote) do |value|
      value == false ? "FALSE" : "'#{value}'"
    end

    dump = adapter.dump_schema
    expect(dump).to include('t.integer "id", primary_key: true, null: false')
    expect(dump).to include('t.boolean "active", default: FALSE, null: false')
  end
end
