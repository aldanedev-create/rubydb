# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "ALTER TABLE constraint execution" do
  it "adds, enforces, drops, and persists a unique constraint" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "constraints.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:email, :text)
      ]
      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, { id: 1, email: "a@example.test" })

      sql = "ALTER TABLE users ADD CONSTRAINT uq_users_email UNIQUE (email)"
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      RubyDB::Execution::Executor.new(engine).execute(plan)

      expect {
        engine.insert_row(:users, columns, { id: 2, email: "a@example.test" })
      }.to raise_error(RubyDB::DatabaseError, /Duplicate value/)

      drop = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("ALTER TABLE users DROP CONSTRAINT uq_users_email").tokenize
      ).parse.first
      RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(drop))
      engine.insert_row(:users, columns, { id: 2, email: "a@example.test" })
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect(reopened.select_rows(:users, reopened.table_columns(:users)).size).to eq(2)
    ensure
      engine&.close if engine&.open?
      reopened&.close if reopened&.open?
    end
  end
end
