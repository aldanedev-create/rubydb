# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../lib/rubydb"

def workload_integer(name, default, minimum: 1)
  value = Integer(ENV.fetch(name, default.to_s), 10)
  raise ArgumentError, "#{name} must be at least #{minimum}" if value < minimum

  value
rescue ArgumentError
  raise ArgumentError, "#{name} must be an integer at least #{minimum}"
end

threads = workload_integer("RUBYDB_WORKLOAD_THREADS", 4)
operations_per_thread = workload_integer("RUBYDB_WORKLOAD_OPERATIONS", 250)
payload_bytes = workload_integer("RUBYDB_WORKLOAD_PAYLOAD_BYTES", 128, minimum: 0)
database_path = ENV["RUBYDB_WORKLOAD_PATH"]
temporary_database = database_path.nil? || database_path.empty?

run = lambda do |path|
  engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
  columns = [
    RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new(:payload, :text, null: false),
    RubyDB::Catalog::Column.new(:worker, :integer, null: false)
  ]
  engine.create_table(:workload_rows, columns)

  next_id = 0
  id_lock = Mutex.new
  start_gate = Queue.new
  errors = Queue.new
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  workers = threads.times.map do |worker_number|
    Thread.new do
      Thread.current.report_on_exception = false
      start_gate.pop
      random = Random.new(worker_number + 1)
      operations_per_thread.times do
        row_id = id_lock.synchronize { next_id += 1 }
        payload = "w#{worker_number}-#{random.bytes(payload_bytes).unpack1('H*')}"
        engine.insert_row(:workload_rows, columns, id: row_id, payload: payload, worker: worker_number)
      end
    rescue StandardError => error
      errors << { worker: worker_number, class: error.class.name, message: error.message }
    end
  end
  threads.times { start_gate << true }
  workers.each(&:join)
  duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  failures = []
  failures << errors.pop until errors.empty?
  raise "workload failures: #{failures.to_json}" unless failures.empty?

  expected_rows = threads * operations_per_thread
  actual_rows = engine.select_rows(:workload_rows, columns).size
  raise "expected #{expected_rows} rows, found #{actual_rows}" unless actual_rows == expected_rows
  engine.close

  reopened = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
  durable_rows = reopened.select_rows(:workload_rows, reopened.table_columns(:workload_rows)).size
  raise "durability check failed: expected #{expected_rows} rows, found #{durable_rows}" unless durable_rows == expected_rows
  reopened.close

  puts JSON.generate(
    threads: threads,
    operations_per_thread: operations_per_thread,
    total_inserts: expected_rows,
    verification_reads: 2,
    duration_seconds: duration.round(4),
    operations_per_second: ((expected_rows * 2) / duration).round(2),
    durable_rows: durable_rows,
    database_bytes: File.size(path)
  )
ensure
  engine&.close if engine&.open?
  reopened&.close if defined?(reopened) && reopened&.open?
end

if temporary_database
  Dir.mktmpdir("rubydb-concurrent-workload") { |dir| run.call(File.join(dir, "workload.rdb")) }
else
  run.call(database_path)
end
