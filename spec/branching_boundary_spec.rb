# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyDB branching boundaries" do
  it "fails closed when the persisted branch catalog is corrupt" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "branches.json"), "not-json")
      engine = Struct.new(:current_lsn).new(0)

      expect {
        RubyDB::Branching::BranchManager.new(engine, branch_dir: dir)
      }.to raise_error(RubyDB::Branching::BranchingError)
    end
  end

  it "reports logical branch changes instead of an empty simulated success" do
    branch = Struct.new(:name, :locked?, :changes, :head_lsn).new("main", false, [], nil)
    manager = Object.new
    manager.define_singleton_method(:get_branch) { |_name| branch }
    manager.define_singleton_method(:current_branch) { branch }

    result = RubyDB::Branching::Diff.new(nil, manager).diff("main", "main")

    expect(result[:success]).to be(true)
    expect(result[:changes]).to eq(added: [], removed: [])
  end

  it "does not claim a branch checkout was applied" do
    branch = Struct.new(:name, :locked?, :changes, :head_lsn).new("feature", false, [], nil)
    manager = Object.new
    manager.define_singleton_method(:get_branch) { |_name| branch }

    result = RubyDB::Branching::Checkout.new(nil, manager).checkout("feature")

    expect(result[:success]).to be(false)
    expect(result[:error]).to include("state-application hook")
  end
end
