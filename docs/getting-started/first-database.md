# First database

```ruby
require "rubydb"

path = "tmp/first-database.rdb"
engine = RubyDB::Storage::Engine.new(path)
engine.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL)")
engine.execute("INSERT INTO accounts (id, email) VALUES (1, 'ada@example.test')")
puts engine.execute("SELECT id, email FROM accounts").inspect
engine.close
```

The engine creates durable storage and WAL state under the selected path. Close
the engine cleanly and keep the database, WAL, and lock files together. A single
embedded path has one owner; use a server for multiple processes.
