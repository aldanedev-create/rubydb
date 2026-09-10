# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL EXISTS subqueries" do
  it "evaluates non-correlated EXISTS predicates" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "exists.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      engine.create_table(:users, columns)
      engine.create_table(:flags, columns)
      engine.insert_row(:users, columns, id: 1)
      engine.insert_row(:flags, columns, id: 1)
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("SELECT id FROM users WHERE EXISTS (SELECT id FROM flags)").tokenize).parse.first

      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))
      expect(result[:rows]).to eq([{"id" => 1}])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "supports NOT EXISTS through the predicate pipeline" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "not-exists.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      engine.create_table(:users, columns)
      engine.create_table(:flags, columns)
      engine.insert_row(:users, columns, id: 1)
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("SELECT id FROM users WHERE NOT EXISTS (SELECT id FROM flags)").tokenize).parse.first

      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))
      expect(result[:rows]).to eq([{"id" => 1}])
    ensure
      engine&.close if engine&.open?
    end
  end
end
