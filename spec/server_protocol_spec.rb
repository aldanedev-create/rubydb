# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

RSpec.describe "RubyDB live server protocol" do
  it "completes handshake and executes queries, prepared statements, and rollback" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 1
      )
      server.engine.create_table(
        "users",
        [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      )
      server.start

      client = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 5, pool_size: 1)
      client2 = nil
      expect(client.connected?).to be(true)
      expect(client.ping).to be(true)
      expect(client.query("INSERT INTO users (id) VALUES (1)").success?).to be(true)
      selected = client.query("SELECT * FROM users").first
      expect(selected[:id] || selected["id"]).to eq(1)

      statement = client.prepare("SELECT * FROM users")
      prepared_row = statement.execute.first
      expect(prepared_row[:id] || prepared_row["id"]).to eq(1)
      statement.close

      transaction = client.begin_transaction
      transaction.query("INSERT INTO users (id) VALUES (2)")
      transaction.rollback
      expect(client.query("SELECT * FROM users").rows.map { |row| row[:id] || row["id"] }).to eq([1])

      client2 = RubyDB::Client::Client.new(host: "127.0.0.1", port: port, timeout: 5, pool_size: 1)
      concurrent = Thread.new { client2.query("SELECT * FROM users").row_count }
      expect(concurrent.value).to eq(1)
      stats = server.stats
      expect(stats[:connections_active]).to be >= 1
      expect(stats[:requests_processed]).to be >= 7
      client.disconnect
      client2.disconnect
      server.stop
    ensure
      client&.disconnect
      client2&.disconnect
      server&.stop
    end
  end

  it "rejects an unsupported protocol version cleanly" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 1
      )
      server.start

      socket = TCPSocket.new("127.0.0.1", port)
      encoder = RubyDB::Protocol::Encoder.new(:json)
      socket.write(encoder.encode(RubyDB::Protocol::Message.new(
        :handshake, { protocol_version: 999, client_name: "invalid" }
      )))
      response = RubyDB::Protocol::Decoder.new.decode(socket.gets, :json)

      expect(response.type).to eq(:handshake_response)
      expect(response.payload[:success]).to be(false)
    ensure
      socket&.close
      server&.stop
    end
  end

  it "returns a protocol error for malformed frames and keeps the session usable" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 1
      )
      server.start

      client = RubyDB::Client::Connection.new(host: "127.0.0.1", port: port, timeout: 5)
      client.connect
      client.socket.write("{not-json}\n")
      error = RubyDB::Protocol::Decoder.new.decode(client.socket.gets, :json)

      expect(error.type).to eq(:error)
      expect(error.payload[:success]).to be(false)
      expect(client.send_ping.type).to eq(:pong)
    ensure
      client&.disconnect
      server&.stop
    end
  end

  it "rejects an oversized request frame" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), max_request_size: 2048,
        min_workers: 1, max_workers: 1
      )
      server.start

      client = RubyDB::Client::Connection.new(host: "127.0.0.1", port: port, timeout: 5)
      client.connect
      client.socket.write("x" * 4096 + "\n")
      error = RubyDB::Protocol::Decoder.new.decode(client.socket.gets, :json)

      expect(error.type).to eq(:error)
      expect(error.payload[:error]).to include("maximum size")
    ensure
      client&.disconnect
      server&.stop
    end
  end

  it "times out an idle connection before it can hold a server slot" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), read_timeout: 0.1,
        min_workers: 1, max_workers: 1
      )
      server.start

      socket = TCPSocket.new("127.0.0.1", port)
      response = RubyDB::Protocol::Decoder.new.decode(socket.gets, :json)

      expect(response.type).to eq(:error)
      expect(response.payload[:error]).to include("timed out")
      expect(socket.gets).to be_nil
    ensure
      socket&.close
      server&.stop
    end
  end

  it "closes active connections during graceful shutdown" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 1
      )
      server.start

      client = RubyDB::Client::Connection.new(host: "127.0.0.1", port: port, timeout: 5)
      client.connect
      expect(server.connection_pool.total_connections).to eq(1)
      expect(server.stop).to be(true)
      expect(server.running?).to be(false)
      expect(server.connection_pool.total_connections).to eq(0)
    ensure
      client&.disconnect
      server&.stop
    end
  end

  it "enforces configured password authentication" do
    Dir.mktmpdir do |dir|
      port_probe = TCPServer.new("127.0.0.1", 0)
      port = port_probe.addr[1]
      port_probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"), min_workers: 1, max_workers: 1,
        authentication: { method: "password", username: "admin", password: "secret" }
      )
      server.start

      valid = RubyDB::Client::Client.new(
        host: "127.0.0.1", port: port, username: "admin", password: "secret", pool_size: 1
      )
      expect(valid.connected?).to be(true)

      expect do
        RubyDB::Client::Client.new(
          host: "127.0.0.1", port: port, username: "admin", password: "wrong", pool_size: 1
        )
      end.to raise_error(RubyDB::ClientError)
      valid.disconnect
    ensure
      valid&.disconnect
      server&.stop
    end
  end

  it "rejects incomplete authentication configuration at startup" do
    Dir.mktmpdir do |dir|
      expect do
        RubyDB::Server::Server.new(
          host: "127.0.0.1", port: 0, data_dir: dir,
          pid_file: File.join(dir, "rubydb.pid"),
          authentication: { method: "password" }
        )
      end.to raise_error(RubyDB::ServerError, /credentials are required/)
    end
  end

  it "rejects incomplete TLS configuration before opening a listener" do
    Dir.mktmpdir do |dir|
      expect do
        RubyDB::Server::Server.new(
          host: "127.0.0.1", port: 0, data_dir: dir,
          pid_file: File.join(dir, "rubydb.pid"),
          ssl: { enabled: true, verify_peer: true }
        )
      end.to raise_error(RubyDB::ServerError, /cert_file and ssl.key_file are required/)
    end
  end

  it "rejects invalid TLS protocol versions at startup" do
    Dir.mktmpdir do |dir|
      cert = File.join(dir, "server.crt")
      key = File.join(dir, "server.key")
      File.write(cert, "not a certificate")
      File.write(key, "not a key")

      expect do
        RubyDB::Server::Server.new(
          host: "127.0.0.1", port: 0, data_dir: dir,
          pid_file: File.join(dir, "rubydb.pid"),
          ssl: { enabled: true, cert_file: cert, key_file: key, min_version: :TLS1_1 }
        )
      end.to raise_error(RubyDB::ServerError, /invalid|TLS1_2 or TLS1_3/)
    end
  end
end
