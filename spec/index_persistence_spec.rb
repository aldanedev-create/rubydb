# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "index persistence and maintenance" do
  it "builds indexes, maintains them on writes, and reloads them" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "indexed.rdb")
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:email, :text, null: false)
      ]
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, [1, "a@example.com"])
      engine.insert_row(:users, columns, [2, "b@example.com"])
      engine.index_manager.create_index(:users_email_idx, :users, [:email], type: :btree)

      index = engine.index_manager.get_index(:users_email_idx)
      expect(index.search("b@example.com")).to eq(2)
      expect(engine.select_rows(:users, columns, email: "b@example.com").map { |row| row[:_row_id] }).to eq([2])
      expect(engine.stats[:index_scans]).to eq(1)
      engine.update_row(:users, 2, { email: "c@example.com" })
      expect(index.search("b@example.com")).to be_nil
      expect(index.search("c@example.com")).to eq(2)
      engine.delete_row(:users, 1)
      expect(index.search("a@example.com")).to be_nil
      engine.index_manager.create_index(:users_email_unique_idx, :users, [:email], type: :btree, unique: true)
      expect { engine.insert_row(:users, columns, [3, "c@example.com"]) }
        .to raise_error(RubyDB::DatabaseError, /unique index/)
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect(reopened.index_manager.index_exists?(:users_email_idx)).to be(true)
      expect(reopened.index_manager.get_index(:users_email_idx).search("c@example.com")).to eq(2)
      reopened.close
    ensure
      engine&.close
      reopened&.close
    end
  end

  it "uses a B-tree for direct range conditions" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "range.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false), RubyDB::Catalog::Column.new(:age, :integer)]
      engine.create_table(:users, columns)
      [[1, 10], [2, 20], [3, 30]].each { |row| engine.insert_row(:users, columns, row) }
      engine.index_manager.create_index(:users_age_idx, :users, [:age], type: :btree)

      rows = engine.select_rows(:users, columns, age: { operator: :gte, value: 20 })
      expect(rows.map { |row| row[:_row_id] }).to eq([2, 3])
      expect(engine.stats[:index_scans]).to eq(1)
      engine.close
    end
  end

  it "uses an index through the SQL planner and executor" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "sql-index.rdb"), auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new("age", :integer)
      ]
      engine.create_table("users", columns)
      engine.insert_row("users", columns, [1, 10])
      engine.insert_row("users", columns, [2, 20])
      engine.index_manager.create_index("age_idx", "users", ["age"])

      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT * FROM users WHERE age >= 20").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      result = RubyDB::Execution::Executor.new(engine).execute(plan)

      expect(plan.scan_type).to eq(:index)
      expect(plan.index.name).to eq("age_idx")
      expect(result[:rows].map { |row| row["id"] }).to eq([2])
      engine.close
    end
  end
end
