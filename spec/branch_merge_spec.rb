# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Branching::Merge do
  it "merges non-conflicting logical changes" do
    source = RubyDB::Branching::Branch.new("feature")
    target = RubyDB::Branching::Branch.new("main")
    source.commit(table: "users", row_id: 2, values: { name: "Grace" })
    manager = Object.new
    manager.define_singleton_method(:get_branch) { |name| { "feature" => source, "main" => target }[name] }
    manager.define_singleton_method(:current_branch_name) { "main" }

    result = described_class.new(nil, manager).merge("feature")

    expect(result[:success]).to be(true)
    expect(target.changes.size).to eq(1)
  end

  it "rejects conflicting changes unless a resolver clears them" do
    source = RubyDB::Branching::Branch.new("feature")
    target = RubyDB::Branching::Branch.new("main")
    source.commit(table: "users", row_id: 2, values: { name: "Grace" })
    target.commit(table: "users", row_id: 2, values: { name: "Ada" })
    manager = Object.new
    manager.define_singleton_method(:get_branch) { |name| { "feature" => source, "main" => target }[name] }
    manager.define_singleton_method(:current_branch_name) { "main" }

    result = described_class.new(nil, manager).merge("feature")

    expect(result[:success]).to be(false)
    expect(result[:conflicts]).not_to be_empty
  end

  it "aborts the last successful merge and restores the target changes" do
    source = RubyDB::Branching::Branch.new("feature")
    target = RubyDB::Branching::Branch.new("main")
    source.commit(table: "users", row_id: 2, values: { name: "Grace" })
    manager = Object.new
    manager.define_singleton_method(:get_branch) { |name| { "feature" => source, "main" => target }[name] }
    manager.define_singleton_method(:current_branch_name) { "main" }

    merger = described_class.new(nil, manager)
    expect(merger.merge("feature")[:success]).to be(true)
    expect(merger.merge_abort).to include(success: true, reverted_changes: 1)
    expect(target.changes).to be_empty
    expect(merger.merge_abort[:success]).to be(false)
  end
end
