# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "physical branch checkout" do
  it "restores a persisted base state and replays branch changes" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)]
      engine.create_table("users", columns)
      engine.insert_row("users", columns, { "id" => 1 })

      manager = RubyDB::Branching::BranchManager.new(engine, branch_dir: File.join(dir, "branches"))
      expect(manager.create_branch("feature", from: "main")[:success]).to be(true)
      manager.checkout("feature")
      manager.commit(operation: "insert", table: "users", values: { "id" => 2 })

      expect(manager.checkout("feature")[:success]).to be(true)
      expect(engine.select_rows("users", columns).map { |row| row["id"] || row[:id] }).to contain_exactly(1, 2)

      engine.close
    end
  end
end
