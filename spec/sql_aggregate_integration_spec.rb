# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL aggregates" do
  it "counts distinct non-null aggregate values" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "distinct.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:value, :integer)]
      engine.create_table(:metrics, columns)
      [1, 1, 2, nil].each { |value| engine.insert_row(:metrics, columns, value: value) }
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("SELECT COUNT(DISTINCT value) AS total FROM metrics").tokenize).parse.first

      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))
      expect(result[:rows]).to eq([{"total" => 2}])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "returns NULL for SUM and AVG over an empty input" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "empty-aggregate.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:value, :integer)]
      engine.create_table(:metrics, columns)
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("SELECT COUNT(*) AS count, SUM(value) AS sum, AVG(value) AS average FROM metrics").tokenize).parse.first

      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))
      expect(result[:rows]).to eq([{"count" => 0, "sum" => nil, "average" => nil}])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "executes grouped and global aggregates with HAVING through the normal SQL pipeline" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "aggregates.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE sales (id INTEGER PRIMARY KEY, region VARCHAR(32), amount INTEGER)")
      connection.execute("INSERT INTO sales (id, region, amount) VALUES (1, 'east', 10)")
      connection.execute("INSERT INTO sales (id, region, amount) VALUES (2, 'east', 15)")
      connection.execute("INSERT INTO sales (id, region, amount) VALUES (3, 'west', 7)")

      grouped = connection.execute(<<~SQL).to_a
        SELECT region, COUNT(*) AS orders, SUM(amount) AS total
        FROM sales GROUP BY region HAVING total >= 20 ORDER BY total DESC
      SQL
      global = connection.execute("SELECT COUNT(*) AS orders, AVG(amount) AS average_amount FROM sales").to_a

      expect(grouped).to eq([{"region" => "east", "orders" => 2, "total" => 25}])
      expect(global).to eq([{"orders" => 3, "average_amount" => (32.0 / 3)}])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
