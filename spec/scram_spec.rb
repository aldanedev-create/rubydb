# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SCRAM-SHA-256 authentication" do
  it "authenticates through the live protocol using a proof" do
    Dir.mktmpdir do |dir|
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close
      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"),
        authentication: {
          method: "scram-sha-256",
          credentials: { username: "alice", password: "correct horse battery staple" }
        }
      )
      server.start

      client = RubyDB::Client::Client.new(
        host: "127.0.0.1", port: port, username: "alice",
        password: "correct horse battery staple", pool_size: 1
      )
      expect(client.connected?).to be(true)
    ensure
      client&.disconnect
      server&.stop
    end
  end

  it "rejects a tampered SCRAM proof" do
    handshake = RubyDB::Protocol::Handshake.new(
      default_auth: "scram-sha-256",
      authentication_credentials: { username: "alice", password: "secret" }
    )
    response = handshake.start(protocol_version: RubyDB::Protocol::ProtocolVersion.current)
    result = handshake.authenticate(
      username: "alice",
      scram_data: {
        client_first_bare: "n=alice,r=nonce",
        client_final_without_proof: "c=biws,r=nonce#{response[:challenge]}",
        client_nonce: "nonce",
        proof: "d3Jvbmc="
      }
    )
    expect(result[:success]).to be(false)
  end
end
