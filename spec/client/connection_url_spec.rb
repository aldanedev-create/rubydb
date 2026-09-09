# frozen_string_literal: true

require "rubydb"

RSpec.describe RubyDB::Client::ConnectionURL do
  it "parses credentials, endpoint, database, and TLS options" do
    config = described_class.parse(
      "rubydbs://app%40user:p%40ss%2Bword@db.example.test:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Fca.crt"
    )

    expect(config).to include(
      host: "db.example.test",
      port: 7432,
      username: "app@user",
      password: "p@ss+word",
      database: "app"
    )
    expect(config[:ssl]).to include(enabled: true, verify_peer: true, ca_file: "/etc/rubydb/ca.crt")
  end

  it "rejects unsupported schemes and missing database names" do
    expect { described_class.parse("postgresql://user:pass@db/app") }.to raise_error(ArgumentError)
    expect { described_class.parse("rubydb://db.example.test") }.to raise_error(ArgumentError)
  end
end
