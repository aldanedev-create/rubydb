# Lesson 3: use RubyDB embedded deliberately

Embedded mode puts the database engine in the application process. It is
simple, fast to start, and useful for local development, command-line tools,
small internal utilities, and a service with one database-owning process.

It is not a shared file protocol. Two independent processes must not open the
same `.rdb` path concurrently. A Rails web server with several worker
processes, or a web server plus a job worker, should use RubyDB server/client
mode instead.

## A safe embedded boundary

```text
one Ruby process
    |
    +-- RubyDB::Storage::Engine
            |
            +-- tmp/service.rdb or /var/lib/service/service.rdb
```

Keep the path outside the source tree and make its owner explicit:

```ruby
require "rubydb"

database_path = ENV.fetch("RUBYDB_DATABASE", "tmp/service.rdb")
engine = RubyDB::Storage::Engine.new(database_path)

begin
  engine.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS jobs (
      id INTEGER PRIMARY KEY,
      state TEXT NOT NULL,
      created_at TIMESTAMP
    )
  SQL

  engine.execute("INSERT INTO jobs (state, created_at) VALUES ('queued', CURRENT_TIMESTAMP)")
  p engine.execute("SELECT id, state FROM jobs ORDER BY id")
ensure
  engine.close
end
```

Use bound values for data. Do not build SQL by interpolating request
parameters, usernames, or search terms.

## Rails embedded configuration

```yaml
development:
  adapter: rubydb
  embedded: true
  database: <%= ENV.fetch("RUBYDB_DATABASE", Rails.root.join("tmp/development.rdb")) %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

For tests, use a different path. For a one-process production service, put the
database on persistent storage, set restrictive filesystem permissions, and
ensure the service manager starts only one owner. If the deployment scales the
service horizontally, embedded mode is the wrong topology.

## Inspect and back up the file

The repository CLI has read-only inspection, verified backup, restore, and
doctor commands:

```sh
rubydb doctor --quick --json
rubydb inspect --database tmp/service.rdb --stats --wal
rubydb backup --database tmp/service.rdb --dir tmp/backups --type full --compress
```

Check the installed command’s help before automating a version-specific option:

```sh
rubydb doctor --help
rubydb backup --help
rubydb restore --help
```

Keep the backup directory on a different disk or host in production. A second
copy on the same failed disk is not a recovery plan.

## What embedded mode does not solve

Embedded mode does not provide a network endpoint, cross-host failover,
automatic leader election, a connection pool shared by processes, or a managed
cloud backup. Those are deployment responsibilities. If the workload needs
them, move to server/client mode or choose a managed PostgreSQL service.

## Checkpoint

Prove that the owner rule is enforceable: document the process that opens the
file, the persistent path, the backup destination, and the restore operator.
Then deliberately run the application with two processes in a disposable test
environment and confirm your deployment prevents shared-file access. Continue
to [lesson 4](04-rails-complex-apps.md) for Rails query and migration validation.
