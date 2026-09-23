# Architecture overview

RubyDB separates logical query processing from durable state changes. SQL is
lexed into tokens, parsed into an AST, bound against catalog metadata, planned,
and executed against the storage engine. DML is coordinated with transactions
and WAL before durable acknowledgement.

The catalog defines tables, columns, constraints, views, and indexes. The page
manager and buffer pool provide durable storage. Recovery replays valid WAL and
rejects malformed or uncertain state. Server/client mode isolates application
processes from the exclusive embedded owner.

Read the [current-state audit](current-state.md) before relying on any feature.

## Copy/paste application entry point

This is the smallest useful embedded service pattern. For web workers or
several processes, use a `RUBYDB_URL` server client as shown in the
[real-world cookbook](../real-world-examples.md).

```ruby
require "rubydb"

db = RubyDB.open(ENV.fetch("RUBYDB_PATH", "tmp/app.rdb"))
begin
  db.execute("CREATE TABLE IF NOT EXISTS health_checks (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  db.insert_many("health_checks", [{ id: 1, name: "orders" }])
  puts db.query("SELECT name FROM health_checks WHERE id = 1").first[:name]
ensure
  db.close
end
```
