# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "openssl"

RSpec.describe "TLS transport" do
  it "accepts an SSL client with the enforced TLS minimum" do
    Dir.mktmpdir do |dir|
      cert_path, key_path = create_certificate(dir)
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.addr[1]
      probe.close

      server = RubyDB::Server::Server.new(
        host: "127.0.0.1", port: port, data_dir: dir,
        pid_file: File.join(dir, "rubydb.pid"),
        ssl: { enabled: true, cert_file: cert_path, key_file: key_path, min_version: :TLS1_2 }
      )
      server.start

      client = RubyDB::Client::Client.new(
        host: "127.0.0.1", port: port, pool_size: 1,
        ssl: { enabled: true, verify_peer: false, min_version: :TLS1_2 }
      )
      expect(client.connected?).to be(true)
    ensure
      client&.disconnect
      server&.stop
    end
  end

  private

  def create_certificate(dir)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = cert
    extension_factory.issuer_certificate = cert
    cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(extension_factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    cert_path = File.join(dir, "server.crt")
    key_path = File.join(dir, "server.key")
    File.binwrite(cert_path, cert.to_pem)
    File.binwrite(key_path, key.to_pem)
    [cert_path, key_path]
  end
end
