# frozen_string_literal: true

# Multi-process network workload. Each child owns one client connection and
# reaches the database only through the server; no child opens database files.
require "json"
require "rbconfig"
require "socket"
require "tempfile"
require "tmpdir"
require "timeout"
require_relative "../lib/rubydb"

processes = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_PROCESSES", "4"), 10)
operations = Integer(ENV.fetch("RUBYDB_SERVER_WORKLOAD_OPERATIONS", "100"), 10)
child_timeout = Float(ENV.fetch("RUBYDB_SERVER_WORKLOAD_CHILD_TIMEOUT", "120"))
raise ArgumentError, "processes and operations must be positive" unless processes.positive? && operations.positive?
raise ArgumentError, "RUBYDB_SERVER_WORKLOAD_CHILD_TIMEOUT must be positive" unless child_timeout.positive?

def terminate_children(children)
  children.each do |pid, _file|
    next unless pid

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH, Errno::ECHILD
      next
    rescue
      begin
        Process.kill("KILL", pid)
      rescue
        nil
      end
    end
  end

  children.each do |pid, _file|
    next unless pid

    begin
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end
  end
end

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
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + child_timeout
    waited_pid = nil
    status = nil
    until waited_pid
      waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
      break if waited_pid
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Timeout::Error, "worker #{pid} exceeded #{child_timeout} seconds"
      end

      sleep 0.05
    end
    file.rewind
    output = file.read
    raise "worker #{pid} failed: #{output}" unless status.success?
    json_line = output.lines.reverse_each.find do |line|
      JSON.parse(line)
      true
    rescue JSON::ParserError
      false
    end
    raise "worker #{pid} did not emit JSON metrics: #{output}" unless json_line

    JSON.parse(json_line, symbolize_names: true)
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
  terminate_children(children || [])
  output_files&.each(&:close!)
  server&.stop
  reopened&.close if defined?(reopened) && reopened&.open?
end
