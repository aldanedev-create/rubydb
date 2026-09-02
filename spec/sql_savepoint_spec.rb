# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL savepoints" do
  it "rolls back only work after the savepoint" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "savepoints.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)]
      engine.create_table("items", columns)
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)
      run_sql = lambda do |sql|
        statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
        executor.execute(planner.plan(statement))
      end

      run_sql.call("BEGIN")
      run_sql.call("INSERT INTO items (id) VALUES (1)")
      run_sql.call("SAVEPOINT before_second")
      run_sql.call("INSERT INTO items (id) VALUES (2)")
      run_sql.call("ROLLBACK TO SAVEPOINT before_second")
      run_sql.call("RELEASE SAVEPOINT before_second")
      run_sql.call("COMMIT")

      expect(engine.select_rows("items", columns, visibility_check: false).map { |row| row["id"] }).to eq([1])
    ensure
      engine&.close if engine&.open?
    end
  end
end
