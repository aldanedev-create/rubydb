# RubyDB server protocol

The client/server protocol uses bounded framed requests and responses with
handshake, authentication, query, prepared statement, transaction, health, and
metrics operations. Frames must be size-limited and malformed input must be
rejected without taking down the server.

Query deadlines and in-flight cancellation are request-scoped. Cancellation is
cooperative and must be checked by long-running execution paths. Do not expose
the listener publicly; use TLS/private networking and rotate credentials through
the documented operations procedure. The normative notes are in
`spec/wire/protocol.md` and `spec/protocol/protocol.md`.

## Copy/paste client timeout check

```ruby
require "rubydb"

client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
begin
  result = client.query("SELECT 1", [], timeout: 2)
  p result.to_hash
ensure
  client.disconnect
end
```

Exercise cancellation and timeout behavior against a staging server before
setting production deadlines.
