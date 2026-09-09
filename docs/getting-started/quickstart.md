# Quick start

Create a local database in one owning Ruby process:

```ruby
require "rubydb"

engine = RubyDB::Storage::Engine.new("tmp/quickstart.rdb")
engine.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
engine.execute("INSERT INTO users (id, name) VALUES (1, 'Aldane')")
p engine.execute("SELECT * FROM users")
engine.close
```

For a full walkthrough see [first database](first-database.md) and
[first query](first-query.md). For multiple processes, use the server/client
topology and do not share an embedded path.
