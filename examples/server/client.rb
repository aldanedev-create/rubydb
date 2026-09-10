# frozen_string_literal: true

# Connect to server.rb (or any RubyDB server) from a separate process.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "rubydb"

url = ENV.fetch("RUBYDB_URL", "rubydb://rubydb@127.0.0.1:7432/rubydb")
client = RubyDB::Client::Client.new(url: url, pool_size: 1, timeout: 5)

begin
  client.query("INSERT INTO messages (id, body) VALUES (1, 'hello from the client') ON CONFLICT DO NOTHING")
  rows = client.query("SELECT id, body FROM messages ORDER BY id").to_a
  puts "Server returned: #{rows.inspect}"
ensure
  client.disconnect
end
