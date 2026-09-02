# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "CREATE TABLE SQL execution" do
  it "preserves table constraints and enforces them on later writes" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "create.rdb"), auto_vacuum: false)
      sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, CONSTRAINT uq_email UNIQUE (email))"
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      RubyDB::Execution::Executor.new(engine).execute(plan)

      columns = engine.table_columns("users")
      engine.insert_row("users", columns, [1, "a@example.test"])
      expect {
        engine.insert_row("users", columns, [2, "a@example.test"])
      }.to raise_error(RubyDB::DatabaseError, /Duplicate value/)
    ensure
      engine&.close if engine&.open?
    end
  end

  it "parses and persists foreign-key referential actions" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "fk-actions.rdb"), auto_vacuum: false)
      parent_sql = "CREATE TABLE parents (id INTEGER PRIMARY KEY)"
      child_sql = "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER, CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES parents (id) ON DELETE CASCADE ON UPDATE CASCADE)"
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)
      [parent_sql, child_sql].each do |sql|
        statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
        executor.execute(planner.plan(statement))
      end

      constraint = engine.table_metadata["children"][:constraints].first
      expect(constraint[:on_delete]).to eq(:cascade)
      expect(constraint[:on_update]).to eq(:cascade)
    ensure
      engine&.close if engine&.open?
    end
  end
end
