# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"
require "tmpdir"

RSpec.describe "replication partition recovery" do
  def available_port
    probe = TCPServer.new("127.0.0.1", 0)
    probe.addr[1]
  ensure
    probe&.close
  end

  def wait_until(timeout: 5)
    Timeout.timeout(timeout) do
      sleep 0.01 until yield
    end
  end

  it "reconnects after a network interruption and catches up from the durable log" do
    Dir.mktmpdir("rubydb-replication-partition") do |dir|
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      primary_engine = RubyDB::Storage::Engine.new(
        File.join(dir, "primary.rdb"), auto_cleanup: false, auto_vacuum: false
      )
      replica_engine = RubyDB::Storage::Engine.new(
        File.join(dir, "replica.rdb"), auto_cleanup: false, auto_vacuum: false
      )
      primary_engine.create_table(:events, columns)

      replication_port = available_port
      primary = RubyDB::Replication::Primary.new(
        primary_engine,
        host: "127.0.0.1",
        replication_port: replication_port,
        log_dir: File.join(dir, "primary-replication-log"),
        fence_path: File.join(dir, "cluster.fence"),
        heartbeat_interval: 0.05,
        replication_timeout: 0.2
      )
      replica = RubyDB::Replication::Replica.new(
        replica_engine,
        primary_host: "127.0.0.1",
        replication_port: replication_port,
        retry_interval: 0.02,
        max_retry_attempts: 100,
        heartbeat_interval: 0.05,
        state_path: File.join(dir, "replica-state.json")
      )

      primary.start
      replica.start
      wait_until { replica.replication_status[:state] == RubyDB::Replication::Replica::STATE_STREAMING }

      primary_engine.begin_transaction
      primary_engine.insert_row(:events, columns, id: 1)
      expect(primary_engine.commit_transaction).to be(true)
      wait_until { replica_engine.table_exists?(:events) }
      wait_until { replica_engine.table_row_count(:events) == 1 }

      # Stopping the replication listener simulates a network partition without
      # allowing a second writer to bypass the primary's fencing lease.
      primary.stop
      wait_until do
        [RubyDB::Replication::Replica::STATE_DISCONNECTED,
         RubyDB::Replication::Replica::STATE_FAILED].include?(replica.replication_status[:state])
      end

      primary.start
      wait_until { replica.replication_status[:state] == RubyDB::Replication::Replica::STATE_STREAMING }
      wait_until do
        primary.get_replication_status[:replicas].any? do |peer|
          peer[:acknowledged_lsn].to_i >= 1
        end
      end

      primary_engine.begin_transaction
      primary_engine.insert_row(:events, columns, id: 2)
      expect(primary_engine.commit_transaction).to be(true)
      wait_until { replica_engine.table_row_count(:events) == 2 }
      expect(primary.replication_log.get_last_lsn).to eq(2)

      expect(replica_engine.select_rows(:events, columns).map { |row| row[:id] || row["id"] })
        .to contain_exactly(1, 2)
      expect(replica.replication_status[:last_received_lsn])
        .to eq(replica.replication_status[:last_replayed_lsn])
    ensure
      replica&.stop
      primary&.stop
      replica_engine&.close if replica_engine&.open?
      primary_engine&.close if primary_engine&.open?
    end
  end
end
