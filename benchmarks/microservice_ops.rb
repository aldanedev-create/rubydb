# frozen_string_literal: true

# Run with: ruby -Ilib benchmarks/microservice_ops.rb
# To shorten a local smoke run: RUBYDB_MICRO_ROWS=1000 RUBYDB_MICRO_SAMPLES=20

require "rubydb"
require "tmpdir"
require "json"
require "etc"

sizes = ENV.fetch("RUBYDB_MICRO_ROWS", "1000,10000,100000").split(",").map { |size| Integer(size) }
samples = Integer(ENV.fetch("RUBYDB_MICRO_SAMPLES", "100"))
raise "sizes and samples must be positive" unless sizes.all?(&:positive?) && samples.positive?

percentile = lambda do |values, fraction|
  sorted = values.sort
  sorted[[(fraction * sorted.size).ceil - 1, 0].max]
end

report = {}
sizes.each do |size|
  Dir.mktmpdir("rubydb-microservice-bench") do |directory|
    path = File.join(directory, "app.rdb")
    open_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    db = RubyDB.open(path, accelerator: {mode: :off}, auto_cleanup: false)
    open_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - open_started) * 1000
    db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    size.times { |n| db.execute("INSERT INTO items (id, name) VALUES (#{n + 1}, 'item')") }

    statements = {
      point_select: "SELECT name FROM items WHERE id = #{size / 2 + 1}",
      limit_10: "SELECT name FROM items LIMIT 10",
      count: "SELECT COUNT(*) AS total FROM items",
      point_update: "UPDATE items SET name = 'changed' WHERE id = #{size / 2 + 1}",
      point_delete: "DELETE FROM items WHERE id = #{size}",
      insert: "INSERT INTO items (id, name) VALUES (#{size}, 'item')"
    }
    timings = Hash.new { |hash, key| hash[key] = [] }
    samples.times do
      statements.each do |operation, sql|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        db.execute(sql)
        timings[operation] << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      end
    end
    close_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    db.close
    close_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - close_started) * 1000
    report[size] = {
      open_ms: open_ms.round(3), close_ms: close_ms.round(3),
      operations: timings.transform_values do |values|
        {p50_ms: percentile.call(values, 0.50).round(3), p95_ms: percentile.call(values, 0.95).round(3),
         p99_ms: percentile.call(values, 0.99).round(3)}
      end
    }
  ensure
    db&.close
  end
end

puts JSON.pretty_generate({ruby: RUBY_VERSION, platform: RUBY_PLATFORM, cpu_count: Etc.nprocessors,
  accelerator: "off", samples: samples, results: report})
