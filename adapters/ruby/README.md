# RubyDB Ruby adapter

The Ruby adapter is the direct Ruby API for embedded and client/server use.
For one owning process, open an embedded engine:

```ruby
require "rubydb"

engine = RubyDB::Storage::Engine.new("tmp/app.rdb")
engine.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
engine.execute("INSERT INTO users (id, name) VALUES (1, 'Aldane')")
engine.close
```

An embedded path has exclusive ownership. Multiple application processes must
connect to a managed RubyDB server through `RubyDB::Client::Client`. Validate
the exact RubyDB SQL subset, backup, restore, workload, and recovery procedure
before using important data. See the root README and `docs/production-readiness.md`.
