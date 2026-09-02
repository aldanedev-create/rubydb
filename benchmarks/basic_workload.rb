# frozen_string_literal: true

require "benchmark"
require "json"
require "tmpdir"
require_relative "../lib/rubydb"

iterations = Integer(ENV.fetch("RUBYDB_BENCHMARK_ITERATIONS", "100"), 10)
raise ArgumentError, "iterations must be positive" unless iterations.positive?

Dir.mktmpdir("rubydb-benchmark") do |dir|
  path = File.join(dir, "benchmark.rdb")
  engine = RubyDB::Storage::Engine.new(path)
  columns = [
    RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new(:payload, :text)
  ]
  engine.create_table(:benchmark_rows, columns)

  insert_seconds = Benchmark.realtime do
    iterations.times { |index| engine.insert_row(:benchmark_rows, columns, [index + 1, "payload-#{index}"]) }
  end
  select_seconds = Benchmark.realtime do
    iterations.times { engine.select_rows(:benchmark_rows, columns, limit: iterations) }
  end
  engine.close

  puts JSON.generate(
    iterations: iterations,
    inserted_rows: iterations,
    selected_rows: iterations * iterations,
    insert_rows_per_second: iterations / insert_seconds,
    select_queries_per_second: iterations / select_seconds,
    database_bytes: File.size(path)
  )
end
