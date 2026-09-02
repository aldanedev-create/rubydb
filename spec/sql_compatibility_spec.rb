# frozen_string_literal: true

require "spec_helper"

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
end
