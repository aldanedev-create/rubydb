# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyDB security boundaries" do
  it "does not silently downgrade unsupported password algorithms" do
    password = RubyDB::Security::Password.new(algorithm: :unknown)

    expect { password.hash("Strong!Pass1") }.to raise_error(ArgumentError, /Unsupported password algorithm/)
  end

  it "fails closed for an unimplemented SCRAM exchange" do
    user = Struct.new(:username, :password_hash, :salt).new("alice", "hash", "salt")
    authentication = RubyDB::Security::Authentication.new(
      method: RubyDB::Security::Authentication::METHOD_SCRAM_SHA256,
      user_store: { "alice" => user }
    )

    result = authentication.authenticate(username: "alice", scram_data: "arbitrary")
    expect(result[:success]).to be(false)
    expect(authentication.stats[:successful]).to eq(0)
  end
end
