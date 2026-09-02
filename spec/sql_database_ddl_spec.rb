# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "database DDL execution" do
  it "executes CREATE DATABASE and DROP DATABASE through the planner" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)

      create = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE DATABASE analytics").tokenize).parse.first
      executor.execute(planner.plan(create))
      expect(engine.catalog.find_database("analytics")).not_to be_nil

      drop = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("DROP DATABASE analytics").tokenize).parse.first
      executor.execute(planner.plan(drop))
      expect(engine.catalog.find_database("analytics")).to be_nil
    ensure
      engine&.close if engine&.open?
    end
  end
end
