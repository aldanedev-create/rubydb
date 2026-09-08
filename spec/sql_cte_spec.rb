# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL common table expressions" do
  it "materializes non-recursive CTEs and permits later CTEs to use earlier ones" do
    Dir.mktmpdir("rubydb-cte") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "cte.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:active, :boolean, null: false)
      ]
      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, id: 1, active: true)
      engine.insert_row(:users, columns, id: 2, active: false)

      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(
        "WITH enabled AS (SELECT id, active FROM users WHERE active = TRUE), ids AS (SELECT id FROM enabled) SELECT id FROM ids"
      ).tokenize).parse.first
      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))

      expect(result[:rows]).to eq([{ "id" => 1 }])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "rejects recursive CTEs explicitly" do
    expect do
      RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("WITH RECURSIVE chain AS (SELECT id FROM nodes) SELECT id FROM chain").tokenize).parse
    end.to raise_error(RubyDB::ParserError, /Recursive CTEs are not supported/)
  end
end
