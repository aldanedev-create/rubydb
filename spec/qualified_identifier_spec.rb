# frozen_string_literal: true

require "spec_helper"

RSpec.describe "qualified SQL identifiers" do
  it "parses table-qualified columns and table-qualified stars" do
    statement = RubyDB::SQL::Parser.new(
      RubyDB::SQL::Lexer.new("SELECT accounts.*, accounts.email FROM accounts WHERE accounts.id = 1").tokenize
    ).parse.first

    expect(statement.columns.first.expression).to be_a(RubyDB::SQL::AST::Star)
    expect(statement.columns.first.expression.table).to eq("accounts")
    expect(statement.columns.last.expression.table).to eq("accounts")
    expect(statement.columns.last.expression.name).to eq("email")
    expect(statement.where.left.table).to eq("accounts")
  end
end
