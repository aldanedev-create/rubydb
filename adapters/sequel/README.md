# RubyDB Sequel adapter

The Sequel adapter is an integration surface for applications that use Sequel.
It should be configured with a RubyDB connection and kept within the SQL and
schema features documented by RubyDB. Use one embedded owner or point all
processes at a RubyDB server; never open the same embedded path independently
from multiple workers.

Before production use, run the application's Sequel schema, query, transaction,
pool, migration, backup, restore, and failure tests. Compatibility is feature-
specific and is not a claim of complete PostgreSQL, MySQL, or SQLite behavior.

## Copy/paste RubyDB fallback smoke test

The checkout currently contains this integration documentation but no
distributable Sequel adapter implementation. Use the RubyDB client/server API
until an adapter package with its own CI and published version is available:

```ruby
require "rubydb"

client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
begin
  p client.query("SELECT id, email FROM users WHERE id = ?", [1], timeout: 2).to_hash
ensure
  client.disconnect
end
```

An adapter contribution must add the Sequel connection, bind handling, schema
introspection, transactions, pool behavior, and a real server integration
suite before it is advertised as production-ready.
