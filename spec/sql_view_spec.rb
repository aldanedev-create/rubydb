# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL views" do
  it "creates, queries, and drops a view" do
    Dir.mktmpdir do |dir|
      catalog = RubyDB::Catalog::Catalog.new
      catalog.create_database("app")
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), catalog: catalog, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer)]
      engine.create_table("users", columns)
      engine.insert_row("users", columns, [7])
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)

      create = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE VIEW active_users AS SELECT * FROM users").tokenize).parse.first
      executor.execute(planner.plan(create))
      idempotent = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE VIEW IF NOT EXISTS active_users AS SELECT * FROM users").tokenize).parse.first
      expect { executor.execute(planner.plan(idempotent)) }.not_to raise_error
      select = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("SELECT * FROM active_users").tokenize).parse.first
      expect(executor.execute(planner.plan(select))[:row_count]).to eq(1)

      drop = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("DROP VIEW active_users").tokenize).parse.first
      executor.execute(planner.plan(drop))
      expect(catalog.find_view("active_users")).to be_nil

      catalog.create_view("persisted_users", "SELECT * FROM users")
      catalog.create_schema("reporting")
      restored = RubyDB::Catalog::Catalog.deserialize(catalog.serialize)
      expect(restored.find_view("persisted_users").query).to eq("SELECT * FROM users")
      expect(restored.find_schema("reporting")).not_to be_nil
    ensure
      engine&.close if engine&.open?
    end
  end
end
