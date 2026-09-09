# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

RSpec.describe "server multi-client durability" do
  it "handles concurrent client inserts and preserves rows after restart" do
    Dir.mktmpdir do |dir|
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close
      server = RubyDB::Server::Server.new(host: "127.0.0.1", port: port, data_dir: dir,
                                           pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 4)
      server.engine.create_table("events", [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)])
      server.start
      clients = 4.times.map { RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 5, pool_size: 1) }
      errors = Queue.new
      clients.each_with_index.map do |client, worker|
        Thread.new do
          20.times { |offset| client.query("INSERT INTO events (id) VALUES (#{worker * 20 + offset + 1})") }
        rescue StandardError => error
          errors << error
        end
      end.each(&:join)
      expect(errors).to be_empty
      expect(clients.first.query("SELECT * FROM events").row_count).to eq(80)
      expect(server.stats[:requests_processed]).to be >= 81
      clients.each(&:disconnect)
      server.stop
      reopened = RubyDB::Storage::Engine.new(File.join(dir, "rubydb.rdb"), auto_cleanup: false)
      expect(reopened.select_rows("events", reopened.table_columns("events")).size).to eq(80)
    ensure
      clients&.each { |client| client.disconnect rescue nil }
      server&.stop
      reopened&.close if reopened&.open?
    end
  end

  it "keeps concurrent client transactions isolated by connection" do
    Dir.mktmpdir do |dir|
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close
      server = RubyDB::Server::Server.new(host: "127.0.0.1", port: port, data_dir: dir,
                                           pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 4)
      server.engine.create_table("events", [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)])
      server.start
      client_one = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 5, pool_size: 1)
      client_two = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 5, pool_size: 1)

      transaction_one = client_one.begin_transaction
      transaction_two = client_two.begin_transaction
      transaction_one.query("INSERT INTO events (id) VALUES (1)")
      transaction_two.query("INSERT INTO events (id) VALUES (2)")
      transaction_one.commit
      transaction_two.rollback

      rows = client_one.query("SELECT * FROM events").rows
      expect(rows.map { |row| row[:id] || row["id"] }).to eq([1])
    ensure
      client_one&.disconnect
      client_two&.disconnect
      server&.stop
    end
  end
end
