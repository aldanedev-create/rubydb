# RubyDB support policy

RubyDB currently supports the documented RubyDB SQL surface, the tested common
SQLite-style profile, the Ruby client/server path, and the ActiveRecord adapter
combinations listed by CI. It does not promise complete PostgreSQL, MySQL, or
SQLite dialect, file-format, extension, or wire compatibility.

When requesting help, include RubyDB commit/version, Ruby and Rails versions,
OS, topology, configuration shape without secrets, a minimal reproduction, and
the exact error. Include workload and recovery evidence for data-safety issues.

For corruption, checksum, replication divergence, or fencing anomalies, stop
writes and preserve the database, WAL, logs, and timestamps before attempting
repair. Report unpatched security issues privately through `SECURITY.md`.

## Copy/paste minimal reproduction

```ruby
require "rubydb"

db = RubyDB.open("tmp/support-repro.rdb")
begin
  db.execute("CREATE TABLE IF NOT EXISTS checks (id INTEGER PRIMARY KEY, value TEXT)")
  db.execute("INSERT INTO checks (id, value) VALUES (1, 'support')")
  p db.query("SELECT * FROM checks")
ensure
  db.close
end
```

Attach the command, sanitized error, RubyDB version, Ruby version, OS, and
topology. Replace the example path with a disposable copy, never production.
