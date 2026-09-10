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

      expect(result[:rows]).to eq([{"id" => 1}])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "evaluates a bounded recursive CTE" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "recursive-cte.rdb"), auto_vacuum: false)
      sql = "WITH RECURSIVE numbers AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM numbers WHERE n < 4) SELECT n FROM numbers ORDER BY n"
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      result = RubyDB::Execution::Executor.new(engine).execute(
        RubyDB::Execution::Planner.new(engine).plan(statement)
      )

      expect(result[:rows]).to eq([
        {"n" => 1}, {"n" => 2}, {"n" => 3}, {"n" => 4}
      ])
      expect(statement.to_sql).to include("WITH RECURSIVE")
    ensure
      engine&.close if engine&.open?
    end
  end
end
