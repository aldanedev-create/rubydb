# frozen_string_literal: true

# Run a local primary and replica, stream a committed row, and verify it.
# This is a single-machine demonstration; production deployments use separate
# hosts and authenticated replication endpoints.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "socket"
require "tmpdir"
require "rubydb"

def free_port
  socket = TCPServer.new("127.0.0.1", 0)
  port = socket.addr[1]
  socket.close
  port
end

Dir.mktmpdir("rubydb-replication") do |directory|
  replication_port = free_port
  columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
  primary_engine = RubyDB::Storage::Engine.new(File.join(directory, "primary.rdb"), auto_cleanup: false)
  replica_engine = RubyDB::Storage::Engine.new(File.join(directory, "replica.rdb"), auto_cleanup: false)
  primary = nil
  replica = nil

  begin
    primary_engine.create_table("events", columns)
    primary = RubyDB::Replication::Primary.new(
      primary_engine,
      host: "127.0.0.1",
      replication_port: replication_port,
      log_dir: File.join(directory, "replication-log"),
      fence_path: File.join(directory, "primary.fence")
    )
    replica = RubyDB::Replication::Replica.new(
      replica_engine,
      primary_host: "127.0.0.1",
      replication_port: replication_port,
      retry_interval: 0.05,
      max_retry_attempts: 20,
      state_path: File.join(directory, "replica-state.json")
    )
    primary.start
    replica.start

    deadline = Time.now + 3
    sleep(0.01) while primary.replicas.empty? && Time.now < deadline
    raise "replica did not connect" if primary.replicas.empty?

    # Primary#write represents a committed logical replication envelope. In a
    # normal application this is emitted by the engine commit listener after
    # the local transaction commits.
    primary.write(id: "event-1", operation: "insert", table_name: "events", values: [1])
    deadline = Time.now + 3
    loop do
      break if replica_engine.table_exists?("events") && replica_engine.table_row_count("events") == 1
      break if Time.now >= deadline
      sleep(0.01)
    end

    rows = replica_engine.select_rows("events", columns)
    raise "replica did not receive the committed row" unless rows.map { |row| row[:id] || row["id"] } == [1]
    puts "Replica caught up: #{rows.inspect}"
  ensure
    replica&.stop
    primary&.stop
    replica_engine.close
    primary_engine.close
  end
end
