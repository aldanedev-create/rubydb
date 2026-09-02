# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "atomic branch checkout" do
  it "does not publish a branch switch when state application fails" do
    Dir.mktmpdir do |dir|
      engine = Object.new
      engine.define_singleton_method(:current_lsn) { 0 }
      engine.define_singleton_method(:export_state) { {} }
      engine.define_singleton_method(:apply_branch_state) { |_state| false }
      manager = RubyDB::Branching::BranchManager.new(engine, branch_dir: dir)
      expect(manager.create_branch("feature", from: "main")[:success]).to be(true)

      result = manager.checkout("feature")

      expect(result[:success]).to be(false)
      expect(manager.current_branch_name).to eq("main")
    end
  end
end
