# MVCC support status

RubyDB currently provides safe READ COMMITTED behavior for the storage engine.
Uncommitted row versions are visible to their owning transaction and hidden
from other transactions. Committed versions become visible after the durable
COMMIT WAL record is written. Deleted physical records remain on pages until
vacuum/compaction and are excluded from ordinary scans.

REPEATABLE READ uses persisted historical row versions and transaction
snapshots. SERIALIZABLE uses snapshot validation over tracked row read/write
keys and conservative table predicates. A newer committed version intersecting
the dependency set aborts commit with a serialization failure. Table-level
predicate tracking prevents phantoms at the cost of false-positive conflicts;
exact index-range predicate locking is a future optimization.

The version store is persisted atomically and supports safe-point vacuuming.
Vacuum never removes active versions and retains the newest committed base
version needed by an active reader; older committed history is removable only
when its commit ID precedes the oldest active transaction.

## Copy/paste visibility check

Use two application requests against the same server for a real concurrency
test. This embedded smoke test verifies the durable transaction path first:

```ruby
require "rubydb"

db = RubyDB.open("tmp/mvcc-example.rdb")
begin
  db.execute("CREATE TABLE IF NOT EXISTS counters (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)")
  db.execute("INSERT INTO counters (id, value) VALUES (1, 0)")
  db.transaction { db.execute("UPDATE counters SET value = value + 1 WHERE id = 1") }
  p db.query("SELECT value FROM counters WHERE id = 1")
ensure
  db.close
end
```
