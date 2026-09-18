#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "../lib/rubydb"

def percentile(values, fraction)
  return 0.0 if values.empty?

  sorted = values.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

def process_metrics(pid)
  return {} unless pid

  host_os = RbConfig::CONFIG.fetch("host_os", "")
  if host_os.match?(/mswin|mingw|cygwin/i)
    command = "(Get-Process -Id #{Integer(pid)} -ErrorAction SilentlyContinue | " \
      "Select-Object CPU,WorkingSet64 | ConvertTo-Json -Compress)"
    output, status = Open3.capture2("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command)
    return {} unless status.success? && !output.strip.empty?

    data = JSON.parse(output)
    return {
      cpu_seconds: data["CPU"].to_f,
      rss_kb: (data["WorkingSet64"].to_i / 1024.0).round
    }
  end

  status_path = "/proc/#{Integer(pid)}/status"
  stat_path = "/proc/#{Integer(pid)}/stat"
  return {} unless File.file?(status_path) && File.file?(stat_path)

  status = File.read(status_path)
  stat = File.read(stat_path).split
  ticks = stat[13].to_i + stat[14].to_i
  {
    cpu_seconds: ticks.to_f / 100.0,
    rss_kb: status[/^VmRSS:\s+(\d+)/, 1]&.to_i
  }
rescue ArgumentError, JSON::ParserError, SystemCallError
  {}
end

def measure(iterations, input_rows, worker_pid: nil)
  samples = []
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ruby_before = process_metrics(Process.pid)
  worker_before = process_metrics(worker_pid)
  output_rows = 0

  iterations.times do
    operation_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    output_rows = result.fetch(:rows).length if result.is_a?(Hash)
    samples << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - operation_started) * 1000.0)
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  ruby_after = process_metrics(Process.pid)
  worker_after = process_metrics(worker_pid)
  {
    iterations: iterations,
    input_rows: input_rows,
    output_rows_per_operation: output_rows,
    elapsed_seconds: elapsed.round(4),
    throughput_rows_per_second: (input_rows * iterations / elapsed).round(2),
    latency_ms: {
      p50: percentile(samples, 0.50).round(3),
      p95: percentile(samples, 0.95).round(3),
      p99: percentile(samples, 0.99).round(3),
      max: samples.max.to_f.round(3)
    },
    ruby_cpu_seconds: (ruby_after[:cpu_seconds].to_f - ruby_before[:cpu_seconds].to_f).round(4),
    ruby_rss_kb_before: ruby_before[:rss_kb],
    ruby_rss_kb_after: ruby_after[:rss_kb],
    worker_cpu_seconds: (worker_after[:cpu_seconds] && worker_before[:cpu_seconds]) ?
      (worker_after[:cpu_seconds] - worker_before[:cpu_seconds]).round(4) : nil,
    worker_rss_kb_before: worker_before[:rss_kb],
    worker_rss_kb_after: worker_after[:rss_kb]
  }
end

def run_concurrent(client, rows, filters, order_by, expected, threads:, requests_per_thread:)
  latencies = Queue.new
  errors = Queue.new
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  workers = threads.times.map do |worker_id|
    Thread.new do
      requests_per_thread.times do
        operation_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          result = client.rows_pipeline(rows, filters: filters, order_by: order_by)
          raise "concurrent result mismatch" unless result[:rows] == expected

          latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - operation_started) * 1000.0)
        rescue => error
          errors << {worker: worker_id, class: error.class.name, message: error.message}
        end
      end
    end
  end
  workers.each(&:join)

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  samples = []
  samples << latencies.pop until latencies.empty?
  failures = []
  failures << errors.pop until errors.empty?
  {
    threads: threads,
    requests: threads * requests_per_thread,
    completed: samples.length,
    errors: failures.length,
    elapsed_seconds: elapsed.round(4),
    throughput_requests_per_second: (samples.length / elapsed).round(2),
    latency_ms: {
      p50: percentile(samples, 0.50).round(3),
      p95: percentile(samples, 0.95).round(3),
      p99: percentile(samples, 0.99).round(3),
      max: samples.max.to_f.round(3)
    },
    first_errors: failures.first(10)
  }
end

row_count = [Integer(ENV.fetch("RUBYDB_ACCELERATOR_ROWS", "10000"), 10), 10_000].max
iterations = Integer(ENV.fetch("RUBYDB_ACCELERATOR_ITERATIONS", "5"), 10)
concurrency = Integer(ENV.fetch("RUBYDB_ACCELERATOR_THREADS", "4"), 10)
requests_per_thread = Integer(ENV.fetch("RUBYDB_ACCELERATOR_REQUESTS", "5"), 10)
raise "iterations must be positive" unless iterations.positive?
raise "threads must be positive" unless concurrency.positive?
raise "requests must be positive" unless requests_per_thread.positive?

rows = row_count.times.map do |id|
  {"id" => id, "bucket" => id % 10, "name" => "row-#{id}", "active" => (id % 7 != 0)}
end
filters = [{column: "bucket", operator: "gte", value: 5}]
order_by = [{column: "id", direction: "desc"}]
ruby_operation = lambda do
  {rows: rows.select { |row| row["bucket"] >= 5 }.sort_by { |row| -row["id"] }}
end
expected = ruby_operation.call.fetch(:rows)

ruby_metrics = measure(iterations, row_count) { ruby_operation.call }

accelerator = RubyDB::Accelerator::Client.new(
  mode: "required",
  binary: ENV["RUBYDB_ACCELERATOR_BIN"],
  timeout: Float(ENV.fetch("RUBYDB_ACCELERATOR_TIMEOUT", "30")),
  min_rows: 0
)
raise "Go accelerator binary is unavailable" unless accelerator.available?

accelerator.ping
first_go = accelerator.rows_pipeline(rows, filters: filters, order_by: order_by)
raise "Ruby and Go results differ before benchmark" unless first_go[:rows] == expected
first_pid = accelerator.stats[:worker_pid]
accelerator.restart
accelerator.ping
second_pid = accelerator.stats[:worker_pid]
go_metrics = measure(iterations, row_count, worker_pid: second_pid) do
  result = accelerator.rows_pipeline(rows, filters: filters, order_by: order_by)
  raise "Ruby and Go results differ during benchmark" unless result[:rows] == expected

  result
end
concurrent_metrics = run_concurrent(
  accelerator, rows, filters, order_by, expected,
  threads: concurrency, requests_per_thread: requests_per_thread
)
accelerator_stats = accelerator.stats

result = {
  rubydb_version: RubyDB::VERSION,
  rows: row_count,
  iterations: iterations,
  workload: "filter bucket >= 5, order by id DESC",
  ruby_only: ruby_metrics.merge(accelerator_mode: "off"),
  go_required: go_metrics.merge(
    accelerator_mode: "required",
    correctness: true,
    worker_first_pid: first_pid,
    worker_second_pid: second_pid,
    worker_restarted: accelerator_stats[:worker_restarts].to_i >= 1,
    concurrency: concurrent_metrics
  ),
  accelerator: accelerator_stats,
  go_fallback_count: 0,
  go_fallback_rate: 0.0,
  fallback_policy: "required mode surfaces accelerator failures; it never silently falls back",
  worker_failure_count: accelerator_stats[:worker_failures].to_i,
  performance_gate_passed: go_metrics[:latency_ms][:p95] < ruby_metrics[:latency_ms][:p95]
}
puts JSON.pretty_generate(result)

if ENV["RUBYDB_ACCELERATOR_REQUIRE_SPEED"] == "1" && !result[:performance_gate_passed]
  warn "Go accelerator did not pass the p95 speed gate"
  accelerator.close
  exit 1
end

accelerator.close
