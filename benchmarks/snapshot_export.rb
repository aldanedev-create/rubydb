# frozen_string_literal: true

# Immutable snapshot export A/B benchmark.
#
# Quick local run:
#   RUBYDB_EXPORT_ROWS=10000 RUBYDB_EXPORT_SAMPLES=3 ruby -Ilib benchmarks/snapshot_export.rb
# Release-sized run:
#   RUBYDB_EXPORT_ROWS=1000000 RUBYDB_EXPORT_SAMPLES=5 ruby -Ilib benchmarks/snapshot_export.rb > export-benchmark.json

require "etc"
require "json"
require "open3"
require "rubydb"
require "tmpdir"

rows = Integer(ENV.fetch("RUBYDB_EXPORT_ROWS", "10000"))
samples = Integer(ENV.fetch("RUBYDB_EXPORT_SAMPLES", "3"))
raise "RUBYDB_EXPORT_ROWS and RUBYDB_EXPORT_SAMPLES must be positive" unless rows.positive? && samples.positive?

def percentile(values, fraction)
  sorted = values.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

def rss_bytes
  if Gem.win_platform?
    output, status = Open3.capture2("powershell", "-NoProfile", "-Command", "(Get-Process -Id #{Process.pid}).WorkingSet64")
    return Integer(output.strip) if status.success? && output.strip.match?(/\A\d+\z/)
  else
    output, status = Open3.capture2("ps", "-o", "rss=", "-p", Process.pid.to_s)
    return Integer(output.strip) * 1024 if status.success? && output.strip.match?(/\A\d+\z/)
  end
rescue SystemCallError, ArgumentError
  nil
end

def run_export(command, arguments, output_path)
  File.delete(output_path) if File.file?(output_path)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  command.execute(arguments + ["--out", output_path], {})
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  {milliseconds: elapsed * 1000, bytes: File.size(output_path), rows: File.foreach(output_path).count}
end

Dir.mktmpdir("rubydb-snapshot-export") do |directory|
  database = File.join(directory, "events.rdb")
  columns = [
    RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new(:service, :text, null: false),
    RubyDB::Catalog::Column.new(:payload, :text, null: false),
    RubyDB::Catalog::Column.new(:active, :boolean, null: false)
  ]
  engine = RubyDB::Storage::Engine.new(database, auto_cleanup: false, auto_vacuum: false,
    accelerator: {mode: :off})
  engine.create_table(:events, columns)
  rows.times do |id|
    engine.insert_row(:events, columns, [id + 1, "orders", "event-#{id + 1}", id.even?])
  end
  engine.close

  command = RubyDB::CLI::Commands::Export.new(RubyDB::CLI::Output.new(no_color: true, quiet: true), nil)
  base_arguments = ["--database", database, "--table", "events", "--columns", "id,service,payload",
    "--where", "active eq true", "--format", "jsonl"]
  report = {}
  %w[ruby go].each do |implementation|
    values = samples.times.map do |sample|
      run_export(command, base_arguments + ["--engine", implementation], File.join(directory, "#{implementation}-#{sample}.jsonl"))
    end
    milliseconds = values.map { |value| value[:milliseconds] }
    report[implementation] = {
      p50_ms: percentile(milliseconds, 0.50).round(3),
      p95_ms: percentile(milliseconds, 0.95).round(3),
      p99_ms: percentile(milliseconds, 0.99).round(3),
      rows: values.first[:rows],
      bytes: values.first[:bytes],
      throughput_rows_per_second: (values.first[:rows] / (percentile(milliseconds, 0.50) / 1000.0)).round(1)
    }
  end
  puts JSON.pretty_generate(
    benchmark: "immutable_snapshot_export",
    rows_seeded: rows,
    samples: samples,
    ruby: RUBY_VERSION,
    platform: RUBY_PLATFORM,
    cpu_count: Etc.nprocessors,
    rss_bytes_after_run: rss_bytes,
    results: report,
    note: "Run with --engine go only after scripts/build_accelerator has produced a verified tool binary."
  )
ensure
  engine&.close if engine&.open?
end
