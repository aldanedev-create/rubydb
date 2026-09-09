# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "documented SQL compatibility" do
  it "parses every documented transaction and maintenance statement" do
    statements = {
      "BEGIN" => RubyDB::SQL::AST::BeginTransaction,
      "COMMIT" => RubyDB::SQL::AST::Commit,
      "ROLLBACK" => RubyDB::SQL::AST::Rollback,
      "SAVEPOINT unit_work" => RubyDB::SQL::AST::Savepoint,
      "ROLLBACK TO SAVEPOINT unit_work" => RubyDB::SQL::AST::RollbackToSavepoint,
      "RELEASE SAVEPOINT unit_work" => RubyDB::SQL::AST::ReleaseSavepoint,
      "VACUUM" => RubyDB::SQL::AST::Vacuum,
      "EXPLAIN SELECT * FROM users" => RubyDB::SQL::AST::Explain
    }

    statements.each do |sql, expected_class|
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      expect(statement).to be_a(expected_class), "expected #{sql} to parse as #{expected_class}"
    end
  end

  it "accepts explicit ascending order direction" do
    statement = RubyDB::SQL::Parser.new(
      RubyDB::SQL::Lexer.new("SELECT id FROM users ORDER BY id ASC").tokenize
    ).parse.first

    expect(statement.order_by.first.direction).to eq(:asc)
  end

  it "updates decimal values through the normal planner and executor" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "sql.rdb"), auto_cleanup: false, auto_vacuum: false)
      execute_sql = lambda do |sql|
        statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
        plan = RubyDB::Execution::Planner.new(engine).plan(statement)
        RubyDB::Execution::Executor.new(engine).execute(plan)
      end
      execute_sql.call("CREATE TABLE prices (id INTEGER PRIMARY KEY, amount DECIMAL)")
      execute_sql.call("INSERT INTO prices (id, amount) VALUES (1, 100.25)")

      expect(execute_sql.call("UPDATE prices SET amount = 125.75 WHERE id = 1")[:row_count]).to eq(1)
      result = execute_sql.call("SELECT amount FROM prices WHERE id = 1")

      expect(result[:rows].first["amount"] || result[:rows].first[:amount]).to eq(125.75)
    ensure
      engine&.close if engine&.open?
    end
  end
end
