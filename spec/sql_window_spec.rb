# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL window functions" do
  it "executes partitioned row numbers and ranks with deterministic ordering" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "windows.rdb"), auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:team, :text, null: false),
        RubyDB::Catalog::Column.new(:score, :integer, null: false)
      ]
      engine.create_table(:scores, columns)
      [[1, "red", 20], [2, "red", 20], [3, "red", 10], [4, "blue", 30]].each do |values|
        engine.insert_row(:scores, columns, values)
      end

      sql = <<~SQL
        SELECT id, team,
               ROW_NUMBER() OVER (PARTITION BY team ORDER BY score DESC) AS row_number,
               RANK() OVER (PARTITION BY team ORDER BY score DESC) AS rank,
               DENSE_RANK() OVER (PARTITION BY team ORDER BY score DESC) AS dense_rank
        FROM scores ORDER BY id
      SQL
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      result = RubyDB::Execution::Executor.new(engine).execute(
        RubyDB::Execution::Planner.new(engine).plan(statement)
      )

      expect(result[:rows].map { |row| row["id"] }).to eq([1, 2, 3, 4])
      red_rows = result[:rows].select { |row| row["team"] == "red" }
      expect(red_rows.map { |row| row["row_number"] }.sort).to eq([1, 2, 3])
      expect(red_rows.map { |row| row["rank"] }).to contain_exactly(1, 1, 3)
      expect(red_rows.map { |row| row["dense_rank"] }).to contain_exactly(1, 1, 2)
      expect(result[:rows].last).to include("row_number" => 1, "rank" => 1, "dense_rank" => 1)
    ensure
      engine&.close if engine&.open?
    end
  end

  it "computes aggregate values over each partition" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "window-aggregates.rdb"), auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:team, :text, null: false),
        RubyDB::Catalog::Column.new(:score, :integer, null: false)
      ]
      engine.create_table(:scores, columns)
      [[1, "red", 20], [2, "red", 10], [3, "blue", 7]].each do |values|
        engine.insert_row(:scores, columns, values)
      end

      sql = "SELECT id, SUM(score) OVER (PARTITION BY team) AS total FROM scores ORDER BY id"
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new(sql).tokenize).parse.first
      result = RubyDB::Execution::Executor.new(engine).execute(
        RubyDB::Execution::Planner.new(engine).plan(statement)
      )

      expect(result[:rows]).to eq([
        { "id" => 1, "total" => 30 },
        { "id" => 2, "total" => 30 },
        { "id" => 3, "total" => 7 }
      ])
    ensure
      engine&.close if engine&.open?
    end
  end
end
