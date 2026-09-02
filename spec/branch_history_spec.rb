# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Branching::Branch do
  it "persists committed logical changes in its serialized state" do
    branch = described_class.new("feature")
    change = { table: "users", row_id: 1, values: { name: "Ada" } }
    branch.commit(change)

    restored = described_class.new("feature", id: branch.id)
    restored.instance_variable_set(:@changes, branch.to_hash[:changes])

    expect(restored.changes).to eq([change])
  end
end
