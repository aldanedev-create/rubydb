# Rails compatibility and integration guide

RubyDB’s ActiveRecord adapter is intended for applications that stay within
the documented RubyDB SQL and schema surface. It is not a claim of complete
Rails compatibility or complete SQLite compatibility. Validate the exact
Rails/Ruby versions, gems, queries, migrations, and deployment topology used
by your application.

## Choose the ownership mode

Embedded mode is appropriate for a single-owner development process or a
deliberately single-process application. Rails web servers, job workers,
console sessions, and migration commands must not independently open the same
embedded path.

For multiple processes, start one RubyDB server and configure every Rails
process to use the client/server adapter. Size the Rails connection pool below
the server’s connection limit and leave headroom for deploys and health
checks.

## First application

Use the maintained example as a smoke harness:

```sh
cd examples/rails_app
bundle install
bundle exec ruby bin/rails db:migrate
bundle exec ruby bin/rails runner 'puts User.count'
bundle exec ruby bin/rails server -b 127.0.0.1 -p 3001
```

Set `RUBYDB_DATABASE` to choose the database path in the embedded example.
Before production, replace the local path with the managed server configuration
and test the same migration and query flow through the network adapter.

## Supported application patterns to validate

Test the application’s real use of:

* model creation, updates, deletes, validations, and transactions;
* `where`, scopes, ordering, limits, offsets, projections, and bind values;
* inner/left/multi-table joins, aliases, grouped aggregates, and `HAVING`;
* eager loading, nested associations, and inverse association behavior;
* connection pools, checkout timeouts, reconnects, and shutdown;
* savepoints, rollback, retry, and deadlock handling;
* schema dump/load, defaults, indexes, foreign keys, and constraints; and
* fresh and populated-table migrations with rollback plans.

Generated SQL is part of the compatibility surface. Capture representative
queries and compare results, affected rows, exceptions, and transaction state.

## Migration discipline

Treat migrations as deployment code. Review generated SQL, run against a fresh
database and a realistic populated copy, measure locks and duration, and
define the rollback/backfill plan. Do not assume that a migration that creates
a table on an empty database is safe on a large live table.

Record the migration version and checksum. A changed migration should be
treated as a new migration or an explicit controlled repair, not silently
accepted. Take a verified backup before destructive schema changes.

## Pooling and concurrency

The pool must return connections with no open transaction, savepoint, lock, or
pending cancellation. Test pool exhaustion and a server restart while Rails
threads are active. Set bounded checkout and request timeouts. A client
timeout does not automatically prove that a write rolled back; use an
idempotency key or query the outcome before retrying.

Run a multi-process workload with web-like reads, writes, jobs, migrations, and
connection churn. Track p95/p99 latency, lock waits, deadlocks, cancellations,
pool utilization, WAL growth, and error classes.

## Version matrix

The repository must run its Rails compatibility suite against every supported
combination, for example Rails 7.1, 7.2, and 8.0 with the Ruby versions declared
by the project. A local pass on one version is not evidence for the matrix.
Record unsupported combinations explicitly in release documentation.

## Debugging adapter failures

Start with [Rails troubleshooting](troubleshooting.md) and
[Debugging RubyDB](../debugging.md). Capture sanitized generated SQL, bind
count/order, transaction boundaries, pool state, Ruby/Rails versions, and the
smallest model/migration that reproduces the failure. Test direct SQL to
separate Rails query generation from engine behavior.

