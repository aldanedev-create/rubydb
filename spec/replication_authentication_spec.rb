# frozen_string_literal: true

require "spec_helper"
require "json"
require "socket"
require "tmpdir"

RSpec.describe "replication endpoint authentication" do
  def available_port
    probe = TCPServer.new("127.0.0.1", 0)
    probe.addr[1]
  ensure
    probe&.close
  end

  it "rejects unauthenticated replication peers when a token is configured" do
    Dir.mktmpdir("rubydb-replication-auth") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "primary.rdb"), auto_cleanup: false, auto_vacuum: false)
      primary = RubyDB::Replication::Primary.new(
        engine,
        host: "127.0.0.1",
        replication_port: available_port,
        replication_auth_token: "cluster-secret",
        fence_path: File.join(dir, "primary.fence"),
        log_dir: File.join(dir, "replication-log")
      )
      primary.start

      socket = TCPSocket.new("127.0.0.1", primary.config[:replication_port])
      socket.write(JSON.generate(type: "replica_handshake", protocol_version: 1, wal_position: 0, auth_token: "wrong") + "\n")
      response = JSON.parse(socket.gets)
      expect(response).to include("success" => false, "error" => "Replication authentication failed")
    ensure
      socket&.close
      primary&.stop
      engine&.close if engine&.open?
    end
  end

  it "accepts a peer with the configured token" do
    Dir.mktmpdir("rubydb-replication-auth-ok") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "primary.rdb"), auto_cleanup: false, auto_vacuum: false)
      primary = RubyDB::Replication::Primary.new(
        engine,
        host: "127.0.0.1",
        replication_port: available_port,
        replication_auth_token: "cluster-secret",
        fence_path: File.join(dir, "primary.fence"),
        log_dir: File.join(dir, "replication-log")
      )
      primary.start

      socket = TCPSocket.new("127.0.0.1", primary.config[:replication_port])
      socket.write(JSON.generate(type: "replica_handshake", protocol_version: 1, wal_position: 0, auth_token: "cluster-secret") + "\n")
      response = JSON.parse(socket.gets)
      expect(response).to include("success" => true, "mode" => "logical")
    ensure
      socket&.close
      primary&.stop
      engine&.close if engine&.open?
    end
  end
end
