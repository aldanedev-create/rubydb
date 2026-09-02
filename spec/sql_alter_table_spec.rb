# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "ALTER TABLE execution" do
  it "adds a column with a default and persists it across reopen" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "alter.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, [1])

      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("ALTER TABLE users ADD age INTEGER DEFAULT 21").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      RubyDB::Execution::Executor.new(engine).execute(plan)

      expect(engine.table_columns(:users).map(&:name).map(&:to_s)).to include("age")
      row = engine.select_rows(:users, engine.table_columns(:users)).first
      expect(row[:age] || row["age"]).to eq(21)
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect(reopened.table_columns(:users).map(&:name)).to include("age")
      expect(reopened.select_rows(:users, reopened.table_columns(:users)).first["age"]).to eq(21)
    ensure
      engine&.close if engine&.open?
      reopened&.close if reopened&.open?
    end
  end

  it "rejects dropping the last column" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "alter.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer)]
      engine.create_table(:users, columns)
      expect { engine.drop_column(:users, :id) }.to raise_error(RubyDB::DatabaseError, /only column/)
    ensure
      engine&.close
    end
  end
end
