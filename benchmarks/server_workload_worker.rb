# frozen_string_literal: true

require "json"
require_relative "../lib/rubydb"

process_number = Integer(ENV.fetch("RUBYDB_PROCESS_NUMBER"), 10)
operations = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_OPERATIONS", "100"), 10)
host = ENV.fetch("RUBYDB_SERVER_WORKLOAD_HOST", "127.0.0.1")
port = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_PORT", "7432"), 10)
latencies = []

begin
  client = RubyDB::Client::Client.new(host: host, port: port, timeout: 30, pool_size: 1)
  operations.times do |operation|
    id = process_number * operations + operation + 1
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = client.query("INSERT INTO workload_rows (id) VALUES (#{id})")
    raise "insert failed: #{result.inspect}" unless result.success?
    latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
  end

  latencies.sort!
  percentile = lambda do |fraction|
    index = ((latencies.length * fraction).ceil - 1).clamp(0, latencies.length - 1)
    latencies[index].round(3)
  end
  puts JSON.generate(process: process_number, operations: operations,
    p50_ms: percentile.call(0.50), p95_ms: percentile.call(0.95),
    p99_ms: percentile.call(0.99))
rescue => error
  warn "process #{process_number} failed: #{error.class}: #{error.message}"
  exit 1
ensure
  client&.disconnect
end
