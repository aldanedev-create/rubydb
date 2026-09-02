# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "base64"

RSpec.describe "standalone SCRAM authentication" do
  it "verifies a stored SCRAM client proof" do
    password = "correct horse battery staple"
    salt = "fixed-test-salt"
    iterations = 4_096
    salted = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, 32, OpenSSL::Digest::SHA256.new)
    client_key = OpenSSL::HMAC.digest("SHA256", salted, "Client Key")
    stored_key = OpenSSL::Digest::SHA256.digest(client_key)
    server_key = OpenSSL::HMAC.digest("SHA256", salted, "Server Key")
    first = "n=alice,r=clientnonce"
    server = "r=clientnonce-servernonce,s=#{Base64.strict_encode64(salt)},i=#{iterations}"
    final = "c=biws,r=clientnonce-servernonce"
    signature = OpenSSL::HMAC.digest("SHA256", stored_key, [first, server, final].join(","))
    proof = client_key.bytes.each_with_index.map { |byte, index| byte ^ signature.getbyte(index) }.pack("C*")

    user = RubyDB::Security::User.new("alice", metadata: {
      scram_salt: Base64.strict_encode64(salt),
      scram_iterations: iterations,
      scram_stored_key: Base64.strict_encode64(stored_key),
      scram_server_key: Base64.strict_encode64(server_key)
    })
    auth = RubyDB::Security::Authentication.new(method: :scram_sha256, user_store: { "alice" => user })

    result = auth.authenticate(
      username: "alice",
      scram_data: {
        client_first_bare: first,
        server_first: server,
        client_final_without_proof: final,
        proof: Base64.strict_encode64(proof)
      }
    )
    expect(result[:success]).to be(true)
  end
end
