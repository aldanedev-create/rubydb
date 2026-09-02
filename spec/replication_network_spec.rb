# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

RSpec.describe "RubyDB logical replication" do
  it "streams row mutations and replays them on a replica" do
    Dir.mktmpdir do |dir|
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close

      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      primary_engine = RubyDB::Storage::Engine.new(File.join(dir, "primary.rdb"), auto_vacuum: false)
      replica_engine = RubyDB::Storage::Engine.new(File.join(dir, "replica.rdb"), auto_vacuum: false)
      primary_engine.create_table("users", columns)
      replica_engine.create_table("users", columns)

      primary = RubyDB::Replication::Primary.new(
        primary_engine, host: "127.0.0.1", replication_port: port,
        log_dir: File.join(dir, "replication-log")
      )
      replica = RubyDB::Replication::Replica.new(
        replica_engine, primary_host: "127.0.0.1", replication_port: port,
        retry_interval: 0.05
      )
      primary.start
      replica.start

      deadline = Time.now + 2
      sleep(0.01) while primary.replicas.empty? && Time.now < deadline
      expect(primary.replicas).not_to be_empty

      primary.write(id: "tx-1", operation: "insert", table_name: "users", values: [11])
      deadline = Time.now + 2
      loop do
        rows = replica_engine.select_rows("users", columns)
        break if rows.any? { |row| (row[:id] || row["id"]) == 11 }
        break if Time.now >= deadline
        sleep(0.01)
      end

      rows = replica_engine.select_rows("users", columns)
      expect(rows.map { |row| row[:id] || row["id"] }).to eq([11])
      expect(replica.replication_status[:transactions_replayed]).to eq(1)
      deadline = Time.now + 1
      until primary.get_replication_status[:replicas].first[:acknowledged_lsn] == 1 || Time.now >= deadline
        sleep(0.01)
      end
      expect(primary.get_replication_status[:replicas].first[:acknowledged_lsn]).to eq(1)
    ensure
      replica&.stop
      primary&.stop
      replica_engine&.close
      primary_engine&.close
    end
  end
end
