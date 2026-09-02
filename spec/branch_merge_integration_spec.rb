# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "persisted branch merge" do
  it "applies a feature branch merge to the live target database" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)]
      engine.create_table("users", columns)
      engine.insert_row("users", columns, { "id" => 1 })
      manager = RubyDB::Branching::BranchManager.new(engine, branch_dir: File.join(dir, "branches"))

      expect(manager.create_branch("feature", from: "main")[:success]).to be(true)
      expect(manager.checkout("feature")[:success]).to be(true)
      expect(manager.commit(operation: "insert", table: "users", values: { "id" => 2 })[:success]).to be(true)
      expect(manager.checkout("main")[:success]).to be(true)

      result = RubyDB::Branching::Merge.new(engine, manager).merge("feature", "main")
      expect(result[:success]).to be(true)
      expect(engine.select_rows("users", columns).map { |row| row["id"] || row[:id] }).to contain_exactly(1, 2)
    ensure
      engine&.close if engine&.open?
    end
  end
end
