#!/usr/bin/env ruby
# frozen_string_literal: true

# A bounded production-oriented server exercise. It intentionally combines
# application traffic with deadline/cancellation, connection-capacity, and
# lock-cycle checks so a deployment run produces one auditable JSON result.

require "json"
require "socket"
require "timeout"
require "tmpdir"
require "thread"
require_relative "../lib/rubydb"

def positive_integer(name, default)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  raise ArgumentError, "#{name} must be at least 1" unless value.positive?

  value
rescue ArgumentError
  raise ArgumentError, "#{name} must be an integer at least 1"
end

def percentile(values, fraction)
  index = [[(values.length * fraction).ceil - 1, 0].max, values.length - 1].min
  values[index].round(3)
end

def wait_until(timeout: 10)
  Timeout.timeout(timeout) do
    loop do
      return true if yield
      sleep 0.02
    end
  end
end

clients = positive_integer("RUBYDB_PRODUCTION_SOAK_CLIENTS", 4)
operations = positive_integer("RUBYDB_PRODUCTION_SOAK_OPERATIONS", 100)
cancel_rows = positive_integer("RUBYDB_PRODUCTION_SOAK_CANCEL_ROWS", 250_000)
cancel_rows = [cancel_rows, 1_000_000].min
cancel_delay = Float(ENV.fetch("RUBYDB_PRODUCTION_SOAK_CANCEL_DELAY", "0.005"))
raise ArgumentError, "RUBYDB_PRODUCTION_SOAK_CANCEL_DELAY must be non-negative" if cancel_delay.negative?

columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
table = "production_soak_rows"
result = nil

Dir.mktmpdir("rubydb-production-soak-") do |directory|
  probe = TCPServer.new("127.0.0.1", 0)
  port = probe.addr[1]
  probe.close
  server = RubyDB::Server::Server.new(
    host: "127.0.0.1",
    port: port,
    data_dir: directory,
    pid_file: File.join(directory, "rubydb.pid"),
    min_workers: 1,
    max_workers: [clients, 4].max,
    max_connections: [clients + 2, 3].max,
    max_recursive_iterations: cancel_rows + 1
  )
  server.engine.create_table(table, columns)
  server.start

  latencies = Queue.new
  errors = Queue.new
  gate = Queue.new
  workers = clients.times.map do |client_number|
    Thread.new do
      client = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 30, pool_size: 1)
      gate.pop
      operations.times do |operation|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = client.query("INSERT INTO #{table} (id) VALUES (#{client_number * operations + operation + 1})")
        raise "insert failed: #{result.error || result.inspect}" unless result.success?

        latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
      end
    rescue StandardError => error
      errors << "#{error.class}: #{error.message}"
    ensure
      client&.disconnect
    end
  end
  clients.times { gate << true }
  workers.each(&:join)
  failures = []
  failures << errors.pop until errors.empty?
  raise "production soak client failures: #{failures.inspect}" unless failures.empty?

  traffic_values = []
  traffic_values << latencies.pop until latencies.empty?
  traffic_values.sort!
  expected_rows = clients * operations
  actual_rows = server.engine.table_row_count(table)
  raise "production soak lost rows: expected #{expected_rows}, got #{actual_rows}" unless actual_rows == expected_rows

  deadline_client = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 30, pool_size: 1)
  deadline = deadline_client.query("SELECT 1", timeout: -1)
  raise "deadline was accepted" unless !deadline.success? && deadline.error.to_s.include?("deadline")
  deadline_client.disconnect

  cancellation_client = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 30, pool_size: 1)
  cancel_sql = "WITH RECURSIVE numbers AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM numbers WHERE n < #{cancel_rows}) SELECT n FROM numbers"
  cancellation_result = nil
  cancellation_requested = false
  3.times do
    handle = cancellation_client.query_async(cancel_sql)
    sleep cancel_delay
    cancellation_requested ||= handle.cancel
    cancellation_result = handle.wait(30)
    break if !cancellation_result.success? && cancellation_result.error.to_s.include?("cancel")
  end
  cancellation_client.disconnect
  unless cancellation_requested && cancellation_result && !cancellation_result.success? && cancellation_result.error.to_s.include?("cancel")
    raise "wire cancellation did not stop the long query: #{cancellation_result&.error || cancellation_result.inspect}"
  end

  capacity = server.config[:max_connections]
  held_sockets = capacity.times.map { TCPSocket.new("127.0.0.1", port) }
  wait_until { server.connection_pool.stats[:current_connections] >= capacity }
  extra_socket = TCPSocket.new("127.0.0.1", port)
  wait_until { server.listener.stats[:connections_rejected].positive? }

  transaction_one = RubyDB::Transactions::Transaction.new(id: "soak-tx-1")
  transaction_two = RubyDB::Transactions::Transaction.new(id: "soak-tx-2")
  lock_manager = RubyDB::Transactions::LockManager.new(lock_timeout: 0.15)
  lock_manager.acquire_lock(transaction_one, "soak", 1, :exclusive, 0.15)
  lock_manager.acquire_lock(transaction_two, "soak", 2, :exclusive, 0.15)
  waits = [
    Thread.new { lock_manager.acquire_lock(transaction_one, "soak", 2, :exclusive, 0.15) },
    Thread.new { lock_manager.acquire_lock(transaction_two, "soak", 1, :exclusive, 0.15) }
  ]
  waits.each(&:join)
  raise "deadlock was not detected" unless lock_manager.stats[:deadlocks_detected].positive?

  result = {
    success: true,
    clients: clients,
    operations_per_client: operations,
    durable_rows: actual_rows,
    p50_ms: percentile(traffic_values, 0.50),
    p95_ms: percentile(traffic_values, 0.95),
    p99_ms: percentile(traffic_values, 0.99),
    deadline_rejected: true,
    cancellation_requested: cancellation_requested,
    cancellation_confirmed: true,
    connection_capacity: capacity,
    connection_rejections: server.listener.stats[:connections_rejected],
    deadlocks_detected: lock_manager.stats[:deadlocks_detected]
  }
ensure
  extra_socket&.close rescue nil
  held_sockets&.each { |socket| socket.close rescue nil }
  deadline_client&.disconnect rescue nil
  cancellation_client&.disconnect rescue nil
  server&.stop rescue nil
end

puts JSON.generate(result) if result
