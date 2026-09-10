# RubyDB

RubyDB is a Ruby-native relational database with an embedded engine, a
client/server mode, a Ruby client, and an ActiveRecord adapter.

> **Status: alpha.** RubyDB is suitable for experimentation, development,
> controlled embedded workloads, and applications that stay within the
> documented and tested feature set. It provides a tested common SQLite-style
> profile, but is not a drop-in replacement for PostgreSQL, MySQL, or SQLite.

## What works today

The repository contains implementation and automated coverage for:

- SQL tables, CRUD, joins, grouping and aggregates, ordering, transactions,
  savepoints, conflict handling, and documented maintenance statements
- typed values, primary/foreign keys, unique and check constraints, and B-tree
  indexes
- durable storage, WAL-backed commits, recovery, snapshots, branching, and
  MVCC paths
- Ruby API, client/server protocol, connection pooling, configuration, and
  operational tooling
- ActiveRecord integration, Rails migrations, and a runnable Rails example

These features are not a guarantee of compatibility with every application.
Run the test suite and validate your own schema, queries, workload, backup,
restore, and failure scenarios before using RubyDB for important data.

## Why “complete PostgreSQL/MySQL/SQLite compatibility” matters

That requirement is only necessary when RubyDB is intended to be a drop-in
replacement for an existing application using one of those databases.

It includes much more than accepting similar `SELECT` statements:

- dialect-specific SQL syntax, functions, operators, casts, and error behavior
- query semantics for joins, `NULL`, ordering, grouping, subqueries, CTEs,
  unions, upserts, and window functions
- data types, indexes, constraints, generated values, and transaction behavior
- migration behavior and ActiveRecord adapter mappings
- client protocol, connection behavior, locking, limits, and operational tools

A new Ruby or Rails application does not need complete compatibility. It can
use RubyDB's documented SQL and adapter behavior directly. Compatibility is
needed to move an existing PostgreSQL, MySQL, or SQLite application without
rewriting queries and without discovering semantic differences in production.

RubyDB currently targets a documented RubyDB SQL subset plus tested Rails
operations. The compatibility documents describe the supported statements;
unsupported or unverified dialect features must not be assumed to work.

## Quick start

Install the prerelease gem:

```sh
gem install rubydb --pre
```

For local development from this repository:

```sh
bundle install
bundle exec rspec
```

## Ruby usage

RubyDB can run embedded in a single owning process:

```ruby
require "rubydb"

engine = RubyDB::Storage::Engine.new("tmp/example.rdb")
engine.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
engine.execute("INSERT INTO users (name) VALUES ('Aldane')")
puts engine.execute("SELECT * FROM users").inspect
engine.close
```

For multiple application processes, use RubyDB's server/client mode and point
clients at the managed server. Do not open the same embedded database path
from multiple independent processes. A regular Ruby application can use a
RubyDB connection URL supplied by its environment:

```ruby
client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
client.query("SELECT 1")
client.disconnect
```

Use the `rubydb://` or TLS-enabled `rubydbs://` format documented in the Rails
configuration guide. RubyDB URLs are not PostgreSQL URLs.

## Rails example

The small Rails 7.2 application in
[`examples/rails_app`](examples/rails_app) runs a real migration, model query,
and browser form through `rubydb-activerecord`.

```sh
cd examples/rails_app
bundle install
bundle exec ruby bin/rails db:migrate
bundle exec ruby bin/rails server -b 127.0.0.1 -p 3001
```

Open <http://127.0.0.1:3001/>. The example uses an embedded database under
`tmp/`; set `RUBYDB_DATABASE` to choose another path. See the adapter and Rails
documentation for network configuration, migrations, production deployment,
backups, restore drills, and monitoring.

For an even smaller end-to-end smoke test, see the tiny GitHub-style app in
[`examples/github_clone`](examples/github_clone). It covers repositories,
issues, commits, Rails associations, foreign keys, indexes, seed data, and a
browser page backed by RubyDB.

## Compatibility policy

RubyDB does not claim complete PostgreSQL, MySQL, or SQLite compatibility until
each compatibility area has both an implementation and repeatable validation.
The project must validate at least:

1. parser and execution behavior for the documented dialect surface
2. type, constraint, transaction, locking, and error semantics
3. ActiveRecord queries, joins, eager loading, associations, and migrations
4. sustained concurrency, cancellation, recovery, backup/restore, and failover
5. supported Ruby, Rails, operating-system, and client/server combinations

Until then, compatibility should be treated as feature-specific, not implied
by the presence of an adapter.

## Documentation

- [Documentation index](docs/README.md)
- [Developer guide](docs/developer-guide.md)
- [Troubleshooting guide](docs/troubleshooting.md)
- [Debugging playbook](docs/debugging.md)
- [Production operations guide](docs/operations/production-guide.md)
- [Lessons learned](docs/lessons-learned.md)
- [Getting started](docs/getting-started/quickstart.md)
- [Local development to production](docs/getting-started/local-to-production.md)
- [SQL compatibility](docs/sql/compatibility.md)
- [SQL compatibility guide](docs/sql/compatibility-guide.md)
- [SQLite compatibility profile](docs/sql/sqlite-compatibility.md)
- [SQL syntax](docs/sql/syntax.md)
- [Rails installation](docs/rails/installation.md)
- [Rails production guidance](docs/rails/production.md)
- [Rails compatibility guide](docs/rails/compatibility-guide.md)
- [Production readiness](docs/production-readiness.md)
- [Operations and workload testing](docs/operations/workload-testing.md)
- [Production runbook](docs/operations/production-runbook.md)
- [CLI guide](docs/cli.md)
- [CLI cheat sheet](docs/cli-cheatsheet.md)
- [Release checklist](docs/release.md)
- [Security policy](SECURITY.md)
- [Contributing and testing](CONTRIBUTING.md)
- [Roadmap](ROADMAP.md)

## License

RubyDB is released under the [MIT License](LICENSE).
