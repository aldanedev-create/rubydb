# Rails production guidance

RubyDB can serve Rails applications that stay within the documented RubyDB SQL
and ActiveRecord adapter surface. Validate the exact Rails, Ruby, operating
system, schema, workload, and deployment topology before handling important
data. The compatibility workflow currently exercises Rails 7.1, 7.2, and 8.0
with Ruby 3.3; hosted workflow results are required before declaring a release
combination supported.

## Choose the topology

An embedded database path has exclusive ownership. Use it only when one Rails
process owns the database, such as a single-process development or controlled
worker deployment. Do not point multiple independent Rails processes at the
same embedded path.

For multiple web/worker processes, run a separately managed RubyDB server and
configure clients to use its network endpoint. Size the server connection
limit for the Rails pool total, keep application and replication traffic on
private networks, and enable TLS and authentication. A Rails connection pool
does not make an embedded file safe for concurrent process ownership.

## Migrations and releases

Before a migration:

1. Run the complete test suite and the adapter suite for the target Rails
   version.
2. Create and verify a full backup, including the WAL chain when applicable.
3. Restore the backup into a separate staging directory and run the migration
   against the restored copy with a representative populated dataset.
4. Test schema dump/load, indexes, defaults, foreign keys, eager loading,
   nested associations, joins, and application write/read smoke queries.

Stop writes or use the deployment's migration lock. RubyDB fails closed when an
already-applied migration changes checksum or disappears. Keep the pre-release
backup and old data directory until the rollback window closes; do not delete
or overwrite the live directory during rollback.

## Operations

Collect request rate/error rate/latency, active connections, WAL and checkpoint
health, filesystem space, recovery-required acknowledgements, and replication
received/replayed LSNs. Alert on readiness failure, repeated errors, failed
flush/checkpoint, low disk space, excessive pool wait, authentication failures,
and replication lag beyond the application RPO.

Run `scripts/restore_drill`, the threaded and multi-process workloads, and
`scripts/replication_failover_drill` on target-like staging infrastructure.
Archive the Ruby version, RubyDB commit, Rails version, host resources, result
JSON, and recovery time with the release record.

## Current boundaries

The adapter is not a complete PostgreSQL, MySQL, or SQLite compatibility layer.
The tested common SQLite-style profile is documented in
[`docs/sql/sqlite-compatibility.md`](../sql/sqlite-compatibility.md). Complex
table rebuilds, generated columns, polymorphic references, adapter-specific
schema features, and dialect-specific SQL require explicit validation before
use. Automatic high-availability election is disabled; failover is an
operator-controlled, fenced procedure described in
[`docs/operations/failover.md`](../operations/failover.md).
