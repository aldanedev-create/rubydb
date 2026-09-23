# Storage engine

The storage engine owns the database path, page manager, buffer pool, catalog,
indexes, WAL, and recovery lifecycle. It serializes durable changes and exposes
Ruby-native operations used by the SQL executor and adapters.

Embedded ownership is exclusive and enforced with an operating-system lock.
Multiple processes must use the server. On failure, callers should preserve the
original directory and recover into a new destination; do not delete WAL or
overwrite the source during investigation.

Storage changes require reopen, crash, fault-injection, corruption, compaction,
and backup/restore coverage. The [lessons learned](../lessons-learned.md) page
explains why these are separate guarantees.

## Copy/paste reopen check

Write a record, close the engine, and reopen the same path. This is a local
durability smoke test, not a substitute for crash or power-loss testing.

```ruby
require "rubydb"

path = "tmp/reopen-example.rdb"
db = RubyDB.open(path)
db.execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
db.insert_many("events", [{ id: 1, name: "deployed" }])
db.close

db = RubyDB.open(path)
begin
  abort "missing durable row" unless db.query("SELECT name FROM events WHERE id = 1").first[:name] == "deployed"
ensure
  db.close
end
```
