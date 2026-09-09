# RubyDB troubleshooting guide

This guide is for developers and operators diagnosing a live or test
deployment. Preserve evidence before attempting recovery. If data is
important, stop writes, copy the database directory and WAL to protected
storage, record the RubyDB version and commit, and work on a copy.

## First response

Collect the smallest useful incident bundle:

```sh
ruby -v
bundle exec ruby -Ilib exe/rubydb --version
bundle exec ruby -Ilib exe/rubydb status --config config/rubydb.yml
bundle exec ruby -Ilib exe/rubydb doctor --config config/rubydb.yml
```

Also record the operating system, deployment topology, database path (without
credentials), configuration checksum, recent migrations, request IDs, error
logs, disk/free-inode state, process list, and whether the failure affects
embedded mode, server mode, or both. Redact passwords, tokens, private keys,
certificate contents, and customer values.

Do not delete WAL files, run vacuum, force promotion, or retry an unknown
commit until the state and evidence are preserved.

## Startup and configuration

### The database will not open

Check that the path is the intended directory, is readable and writable by the
service account, and is not already owned by another embedded process. Inspect
the status and doctor output. If the path contains an incomplete checkpoint,
use the documented recovery flow and keep the original directory unchanged.

Common causes are a wrong working directory, a missing parent directory,
permissions, a stale lock, an unsupported format version, and an incomplete
restore. A stale lock must be investigated against the process owner; never
remove it merely because startup is inconvenient.

### The server starts and immediately exits

Run the same command in the foreground with verbose logging. Validate the
configuration, TLS files, certificate/key pairing, authentication settings,
listen address, and port availability. Check the service manager’s stdout and
stderr rather than only its health endpoint. `RUBYDB_DEBUG=1` can expose a
development backtrace; do not enable verbose debug output on a public service
without reviewing sensitive data exposure.

### The server is healthy but clients cannot connect

Confirm the client endpoint, port, TLS mode, CA path, SNI/hostname, and
authentication credentials. Test from the same network namespace as the
application. A listening socket proves only that a process has bound a port;
the readiness check must also verify the database owner and request path.

## SQL and query failures

### A statement is rejected

Capture the exact SQL shape with values redacted and determine whether the
failure is parser, binder, planner, executor, or constraint related. Compare
the statement against [SQL compatibility](sql/compatibility.md) and the
[SQLite-style profile](sql/sqlite-compatibility.md). Test a minimal statement
with one table, then add joins, predicates, grouping, and constraints one at a
time.

Do not assume that syntax accepted by SQLite, PostgreSQL, or MySQL has the
same semantics in RubyDB. Unsupported dialect features should be rewritten or
tracked as compatibility work, not hidden behind a generic fallback.

### Results are wrong or unstable

Reproduce without the optimizer if that diagnostic mode exists, then compare
the plan and row versions. Add explicit ordering when order is part of the
application contract. Check `NULL` predicates, implicit casts, duplicate join
keys, grouping columns, transaction snapshot, and stale statistics. Preserve
the schema, seed data, SQL, and expected result as a regression spec.

### A query is slow

Record query shape, row count, indexes, bind values, plan, duration, lock wait,
and whether the delay is execution or checkpoint/WAL pressure. Test with and
without the suspected index and inspect the scan cardinality. Do not add
indexes blindly: each index adds write, storage, recovery, and vacuum cost.

## Transactions, locks, and concurrency

### Requests hang

Separate network wait, lock wait, disk wait, and executor work. Check active
transactions, lock owners, waiters, deadlines, and cancellation logs. Set a
bounded request/lock timeout in staging and capture a thread dump. A timeout
must release resources and report whether commit was known.

### Deadlock detected

Keep the deadlock graph, victim transaction ID, SQL fingerprints, and lock
order. Confirm that the victim rolled back all writes and released every lock.
Retry only idempotent application work. Fix the application’s lock ordering or
transaction size; do not disable deadlock detection.

### Data disappears inside a transaction

Check snapshot timing, savepoints, rollback paths, and whether the read and
write use the same connection. In server mode, a transaction is connection
scoped unless the API says otherwise. A connection-pool checkout must not
reuse a connection with an open transaction.

### High concurrency causes errors

Reduce workers and payload size, then increase one at a time. Monitor memory,
file descriptors, WAL growth, checkpoint time, lock waits, cancellation rate,
and p99 latency. Embedded mode has one process owner; use server mode for
multiple application processes. Use the production soak scripts before
changing limits.

## WAL, recovery, and corruption

### Recovery takes too long

Measure WAL size, last checkpoint LSN, frame count, page count, and storage
latency. A large WAL may indicate a blocked checkpoint, a long reader, or
insufficient checkpoint scheduling. Preserve the directory, then run a copy
through inspection and compaction. Never truncate WAL by hand.

### Checksum or framing validation fails

Treat this as a durability incident. Stop writes, preserve all database and WAL
files, capture filesystem and process termination evidence, and attempt restore
from the newest verified backup in a separate directory. Compare checksums and
LSNs. If the backup also fails, escalate with the complete evidence bundle.

### An index is inconsistent

Do not make application decisions from a suspect index. Run the supported
inspection/recovery or rebuild operation on a copy, compare indexed and table
scans, and verify after reopen. The repair result must be durable before the
copy is promoted. A failed index persistence operation must remain visible as
an error.

### Disk is full

Stop growth safely: pause writes if necessary, preserve logs, and identify
database, WAL, backup, and temporary-file usage. Free capacity through the
host’s approved procedure, then verify the filesystem and resume with a
controlled write. Do not delete WAL, active checkpoints, or the newest backup
to make room.

## Backup, restore, and upgrades

### Backup succeeds but restore fails

Check the backup manifest, checksum, base identity, LSN range, compression,
RubyDB version, and free space in the target directory. Restore to a fresh
directory and run integrity, schema, row-count, and application smoke checks.
Keep the failed restore for diagnosis.

### Incremental/differential chain is rejected

Restore the verified base first and apply deltas in order. Confirm that the
declared base checksum and LSN match. Missing or reordered pieces must fail
closed; do not bypass validation.

### An upgrade will not start

Read the upgrade guard and format version. Take a verified backup, test the
upgrade on a copy with a representative workload, and retain a rollback plan.
Do not mix binary versions against a live embedded directory unless the
compatibility contract explicitly allows it.

## Replication and failover

### Replica is behind

Compare primary and replica acknowledged LSN, WAL retention, connection state,
authentication, and apply errors. Check that the replica is not accepting
writes. Reconnect/catch up through the supported protocol and verify row and
LSN consistency before promotion.

### Promotion is rejected

Promotion should require a synchronized candidate and a valid fencing epoch.
Resolve lag, stale metadata, or fence ownership first. Never force promotion
because an application health check is red; a stale primary may still be able
to write.

### Suspected split brain

Fence both writers at the deployment layer, stop application writes, preserve
both logs and WALs, and identify the highest acknowledged commit/fence epoch.
Do not merge divergent database directories manually. The current RubyDB
workflow is explicitly fenced/manual unless a deployment has separately
validated its election and fencing system across hosts.

## Rails and migrations

Check the Rails/Ruby versions, adapter configuration, connection pool size,
database ownership mode, generated SQL, bind values, and migration version.
Run `db:migrate:status`, inspect schema state, and compare the schema dump with
the intended model. For a populated-table migration, test on a copy and plan
backfill, locking, rollback, and deployment sequencing.

Frequent causes include unsupported generated SQL, an embedded path shared by
web and job processes, pool size exceeding server capacity, a migration
checksum mismatch, or a schema dump that uses a feature outside RubyDB’s
documented profile. See [Rails compatibility](rails/compatibility-guide.md)
and [Rails troubleshooting](rails/troubleshooting.md).

## TLS, authentication, and authorization

Verify the server certificate chain, hostname, expiration, key permissions,
CA bundle, and client/server TLS settings. Rotate certificates by staging the
new chain, testing a client, switching atomically, and retaining the old chain
only for the documented overlap period. Rotate secrets through the secret
manager, not source control or command-line history.

Authentication success does not imply authorization. Check the authenticated
identity, role, operation, database, and audit record. Treat repeated failures
as a security event and preserve timestamps and request IDs.

## Resource exhaustion

Track open files, memory, threads, CPU, disk bytes, inodes, WAL size, active
transactions, pool utilization, and queue depth. Apply limits at the service
and application layers. Reduce concurrency before raising limits, and confirm
that cancellation and shutdown drain work without corrupting state.

## Evidence and escalation

An actionable report includes:

* exact command/API and a minimal reproduction;
* RubyDB commit/version, Ruby/Rails versions, OS and filesystem;
* topology, configuration names, and relevant metrics;
* sanitized logs with request/transaction/LSN identifiers;
* database/WAL/backup checksums and sizes;
* expected versus actual result; and
* what was already attempted and whether it changed state.

See [Debugging RubyDB](debugging.md) for collection commands and safe
instrumentation.

