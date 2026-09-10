# frozen_string_literal: true

# Network-protocol workload smoke test. It deliberately verifies durable rows
# after server shutdown and reopen; use environment variables to scale it on
# deployment hardware.
require "json"
require "socket"
require "tmpdir"
require_relative "../lib/rubydb"

clients = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_CLIENTS", "4"), 10)
operations = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_OPERATIONS", "100"), 10)
raise ArgumentError, "clients and operations must be positive" unless clients.positive? && operations.positive?

Dir.mktmpdir("rubydb-server-workload") do |dir|
  probe = TCPServer.new("127.0.0.1", 0)
  port = probe.addr[1]
  probe.close
  server = RubyDB::Server::Server.new(host: "127.0.0.1", port: port, data_dir: dir,
    pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: [clients, 4].max)
  server.engine.create_table(:workload_rows, [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)])
  database_path = server.engine.path
  server.start
  latencies = Queue.new
  errors = Queue.new
  gate = Queue.new
  workers = clients.times.map do |client_number|
    Thread.new do
      client = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 10, pool_size: 1)
      gate.pop
      operations.times do |operation|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.query("INSERT INTO workload_rows (id) VALUES (#{client_number * operations + operation + 1})")
        raise "insert failed: #{result.error || result.inspect}" unless result.success?
        latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      end
      client.disconnect
    rescue => error
      errors << "#{error.class}: #{error.message}"
    end
  end
  clients.times { gate << true }
  workers.each(&:join)
  failures = []
  failures << errors.pop until errors.empty?
  raise "server workload failures: #{failures.inspect}" unless failures.empty?
  expected = clients * operations
  in_memory_rows = server.engine.table_row_count(:workload_rows)
  raise "in-memory row count failed: expected #{expected}, got #{in_memory_rows}" unless in_memory_rows == expected
  server.stop
  reopened = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
  durable_rows = reopened.select_rows(:workload_rows, reopened.table_columns(:workload_rows)).size
  reopened.close
  raise "durability check failed: expected #{expected}, got #{durable_rows}" unless durable_rows == expected
  values = []
  values << latencies.pop until latencies.empty?
  values.sort!
  percentile = ->(fraction) { values[[(values.length * fraction).ceil - 1, 0].max].round(3) }
  puts JSON.generate(clients: clients, operations_per_client: operations,
    in_memory_rows: in_memory_rows, durable_rows: durable_rows,
    p50_ms: percentile.call(0.50), p95_ms: percentile.call(0.95), p99_ms: percentile.call(0.99))
ensure
  server&.stop
  reopened&.close if defined?(reopened) && reopened&.open?
end
