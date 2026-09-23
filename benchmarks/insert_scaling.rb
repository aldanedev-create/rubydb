# frozen_string_literal: true

# Run with: ruby -Ilib benchmarks/insert_scaling.rb
# Optional: RUBYDB_SCALING_SIZES=1000,5000,20000,50000

require "rubydb"
require "tmpdir"
require "json"
require "etc"

sizes = ENV.fetch("RUBYDB_SCALING_SIZES", "1000,5000,20000,50000").split(",").map { |size| Integer(size) }
raise "sizes must be positive and increasing" unless sizes.all?(&:positive?) && sizes == sizes.sort.uniq

results = {}
%w[primary_key unique].each do |kind|
  results[kind] = {}
  %w[single batch].each do |mode|
    Dir.mktmpdir("rubydb-insert-scaling") do |directory|
      engine = RubyDB::Storage::Engine.new(File.join(directory, "bench.rdb"), auto_cleanup: false,
        accelerator: {mode: :off})
      columns = if kind == "primary_key"
        [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      else
        [RubyDB::Catalog::Column.new(:id, :integer, unique: true, null: false)]
      end
      engine.create_table(:items, columns)
      previous = 0
      blocks = []
      sizes.each do |target|
        gc_before = GC.stat
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rows = (previous...target).map { |n| {id: n + 1} }
        if mode == "batch"
          engine.insert_rows(:items, columns, rows)
        else
          rows.each { |row| engine.insert_row(:items, columns, row) }
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        gc_after = GC.stat
        blocks << {
          from: previous + 1,
          to: target,
          seconds: elapsed.round(3),
          rows_per_second: ((target - previous) / elapsed).round(1),
          allocated_objects: gc_after[:total_allocated_objects] - gc_before[:total_allocated_objects],
          gc_runs: gc_after[:count] - gc_before[:count]
        }
        previous = target
      end
      results[kind][mode] = blocks
    ensure
      engine&.close if engine&.open?
    end
  end
end

puts JSON.pretty_generate({ruby: RUBY_VERSION, platform: RUBY_PLATFORM, cpu_count: Etc.nprocessors,
  sync: true, rows: sizes, results: results})
