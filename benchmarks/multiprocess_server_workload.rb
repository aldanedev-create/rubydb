# frozen_string_literal: true

# Multi-process network workload. Each child owns one client connection and
# reaches the database only through the server; no child opens database files.
require "json"
require "rbconfig"
require "socket"
require "tempfile"
require "tmpdir"
require_relative "../lib/rubydb"

processes = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_PROCESSES", "4"), 10)
operations = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_OPERATIONS", "100"), 10)
raise ArgumentError, "processes and operations must be positive" unless processes.positive? && operations.positive?

Dir.mktmpdir("rubydb-multiprocess-workload") do |dir|
  probe = TCPServer.new("127.0.0.1", 0)
  port = probe.addr[1]
  probe.close
  server = RubyDB::Server::Server.new(host: "127.0.0.1", port: port, data_dir: dir,
                                      pid_file: File.join(dir, "rubydb.pid"),
                                      min_workers: 1, max_workers: [processes * 2, 4].max)
  server.engine.create_table(:workload_rows, [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)])
  database_path = server.engine.path
  server.start
  worker = File.expand_path("server_workload_worker.rb", __dir__)
  lib_path = File.expand_path("../lib", __dir__)
  output_files = processes.times.map { Tempfile.new(["rubydb-worker-", ".log"]) }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  children = processes.times.map do |process_number|
    environment = {
      "RUBYDB_PROCESS_NUMBER" => process_number.to_s,
      "RUBYDB_SERVER_WORKLOAD_HOST" => "127.0.0.1",
      "RUBYDB_SERVER_WORKLOAD_PORT" => port.to_s,
      "RUBYDB_SERVER_WORKLOAD_OPERATIONS" => operations.to_s
    }
    pid = Process.spawn(environment, RbConfig.ruby, "-I", lib_path, worker,
                        out: output_files[process_number].path,
                        err: output_files[process_number].path)
    [pid, output_files[process_number]]
  end

  results = children.map do |pid, file|
    _waited_pid, status = Process.wait2(pid)
    file.rewind
    output = file.read
    raise "worker #{pid} failed: #{output}" unless status.success?
    JSON.parse(output.lines.last, symbolize_names: true)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  server.stop
  reopened = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
  durable_rows = reopened.select_rows(:workload_rows, reopened.table_columns(:workload_rows)).size
  expected = processes * operations
  raise "durability check failed: expected #{expected}, got #{durable_rows}" unless durable_rows == expected
  puts JSON.generate(processes: processes, operations_per_process: operations,
                     durable_rows: durable_rows, elapsed_seconds: elapsed.round(3),
                     workers: results)
ensure
  output_files&.each(&:close!)
  server&.stop
  reopened&.close if defined?(reopened) && reopened&.open?
end
