# Temporal data

MVCC keeps row versions long enough for active transaction visibility and safe
vacuum. Readers observe a transaction-consistent view according to the selected
isolation behavior; uncommitted changes are not published to other readers.

Long-running transactions retain old versions and can increase storage. Monitor
transaction age and vacuum/compaction duration, and terminate or redesign stale
work before it affects the workload. Test temporal behavior with restart and
rollback, not only a single read.

## Copy/paste versioned write check

```ruby
require "rubydb"

db = RubyDB.open("tmp/temporal-example.rdb")
begin
  db.execute("CREATE TABLE IF NOT EXISTS profiles (id INTEGER PRIMARY KEY, display_name TEXT)")
  db.execute("INSERT INTO profiles (id, display_name) VALUES (1, 'Ada')")
  db.transaction { db.execute("UPDATE profiles SET display_name = 'Ada Lovelace' WHERE id = 1") }
  p db.query("SELECT display_name FROM profiles WHERE id = 1")
ensure
  db.close
end
```
