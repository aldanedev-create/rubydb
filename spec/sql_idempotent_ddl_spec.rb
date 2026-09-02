# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "idempotent SQL DDL" do
  it "preserves IF NOT EXISTS and IF EXISTS through parse and execution" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)

      create = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE DATABASE IF NOT EXISTS analytics").tokenize).parse.first
      executor.execute(planner.plan(create))
      expect { executor.execute(planner.plan(create)) }.not_to raise_error

      drop = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("DROP DATABASE IF EXISTS missing").tokenize).parse.first
      expect { executor.execute(planner.plan(drop)) }.not_to raise_error
    ensure
      engine&.close if engine&.open?
    end
  end
end
