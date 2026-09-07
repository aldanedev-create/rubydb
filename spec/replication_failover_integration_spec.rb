# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"
require "tmpdir"

RSpec.describe "logical replication failover" do
  def wait_until(timeout: 5)
    Timeout.timeout(timeout) do
      sleep 0.01 until yield
    end
  end

  def available_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  it "replays a logical write to a second engine before manually promoting it" do
    Dir.mktmpdir("rubydb-failover") do |dir|
      primary_engine = RubyDB::Storage::Engine.new(File.join(dir, "primary.rdb"), auto_cleanup: false, auto_vacuum: false)
      replica_engine = RubyDB::Storage::Engine.new(File.join(dir, "replica.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:message, :text, null: false)
      ]
      primary_engine.create_table(:events, columns)
      replica_engine.create_table(:events, columns)

      replication_port = available_port
      primary = RubyDB::Replication::Primary.new(
        primary_engine,
        host: "127.0.0.1",
        replication_port: replication_port,
        log_dir: File.join(dir, "primary-replication-log"),
        fence_path: File.join(dir, "primary.fence"),
        heartbeat_interval: 60
      )
      manager = RubyDB::Replication::ReplicationManager.new(
        replica_engine,
        mode: :replica,
        primary_host: "127.0.0.1",
        replication_port: replication_port,
        retry_interval: 0.01,
        max_retry_attempts: 100,
        health_check_interval: 60,
        fence_path: File.join(dir, "replica.fence")
      )

      primary.start
      manager.start
      wait_until { manager.replica.replication_status[:state] == RubyDB::Replication::Replica::STATE_STREAMING }

      primary_engine.insert_row(:events, columns, id: 1, message: "committed before failover")
      primary.write(operation: :insert, table: :events, values: { id: 1, message: "committed before failover" })
      begin
        wait_until { replica_engine.select_rows(:events, columns).any? }
      rescue Timeout::Error
        raise "replica did not replay the write: #{manager.replica.replication_status.inspect} #{manager.replica.stats.inspect}"
      end

      primary.stop
      result = manager.promote_to_primary

      expect(result).to include(success: true)
      expect(manager.mode).to eq(RubyDB::Replication::ReplicationManager::MODE_PRIMARY)
      expect(manager.primary.get_replication_status).to include(running: true, role: "primary")
      expect(replica_engine.select_rows(:events, columns)).to include(hash_including(id: 1, message: "committed before failover"))
    ensure
      manager&.stop
      primary&.stop
      primary_engine&.close if primary_engine&.open?
      replica_engine&.close if replica_engine&.open?
    end
  end
end
