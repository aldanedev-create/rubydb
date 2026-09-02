# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "schema DDL execution" do
  it "creates and drops schemas through SQL" do
    Dir.mktmpdir do |dir|
      catalog = RubyDB::Catalog::Catalog.new
      catalog.create_database("app")
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), catalog: catalog, auto_vacuum: false)
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)

      create = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE SCHEMA IF NOT EXISTS reporting").tokenize).parse.first
      executor.execute(planner.plan(create))
      expect(catalog.find_schema("reporting")).not_to be_nil

      drop = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("DROP SCHEMA IF EXISTS reporting").tokenize).parse.first
      executor.execute(planner.plan(drop))
      expect(catalog.find_schema("reporting")).to be_nil
    ensure
      engine&.close if engine&.open?
    end
  end
end
