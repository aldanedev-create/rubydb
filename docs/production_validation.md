# Production validation checkpoint

This checkpoint validates the embedded RubyDB engine and ActiveRecord adapter
against a focused, repeatable set of production-relevant paths. Passing it is
evidence for these paths; it is not a claim of universal SQL or Rails
compatibility.

## Validated paths

- ActiveRecord 7.2 embedded CRUD, Arel bind compilation, qualified columns,
  association-generated `INNER JOIN`, and `LEFT OUTER JOIN` SQL execution.
- Reversible Rails migrations covering `create_table`, automatic integer `id`,
  `add_column` with a default, unique `add_index`, and their `down` operations.
- Repeated threaded insert workloads with row-count and close/reopen durability
  verification.
- Four independent network clients concurrently inserting through the live
  server, with request metrics and post-restart durable-row verification.
- Independent concurrent client transactions are isolated by connection:
  committed work remains visible while a sibling transaction's work is rolled
  back.
- Two-engine logical replication of an insert followed by explicit, manual
  promotion of the synchronized replica. Promotion retains the replicated row
  and starts a fenced primary listener. Replicas reject local engine mutations
  while allowing the internal logical replay path; explicit promotion restores
  local writes. Replication TCP input is newline-frame buffered, rejects
  oversized incomplete frames, bootstraps a new replica's catalog before row
  replay, and persists the replay position before ack.
- A stopped primary closes established replication sockets; a replica detects
  the interruption, reconnects after the listener returns, and catches up from
  the durable replication log. A caught-up disconnected replica may be
  explicitly promoted, while lagging or never-synchronized replicas remain
  ineligible.
- Engine transaction integration: a committed transaction containing multiple
  row mutations is emitted as one replication envelope only after its local
  WAL commit and flush complete.
- Persistence safety at the engine boundary: malformed metadata and failed WAL
  recovery abort startup, metadata publishes are fsynced before atomic rename,
  and the maintenance worker is joined before storage closes.
- SQL window ranking (`ROW_NUMBER`, `RANK`, `DENSE_RANK`) and partition-wide
  aggregate windows have focused regression coverage.

## Run before a release

```powershell
bundle exec rspec

# Short CI-style repeatability check
bundle exec rspec spec/concurrent_soak_harness_spec.rb

# Deployment-sized threaded durability soak (adjust to the target hardware)
$env:RUBYDB_SOAK_ROUNDS = "10"
$env:RUBYDB_SOAK_THREADS = "16"
$env:RUBYDB_SOAK_OPERATIONS = "10000"
$env:RUBYDB_SOAK_PAYLOAD_BYTES = "512"
ruby benchmarks/concurrent_soak.rb

# Network server/client durability and latency smoke. Increase these values on
# target hardware and archive the JSON p50/p95/p99 result with the release.
$env:RUBYDB_SERVER_WORKLOAD_CLIENTS = "16"
$env:RUBYDB_SERVER_WORKLOAD_OPERATIONS = "1000"
ruby -Ilib benchmarks/server_workload.rb

# Independent client processes through the server. This validates process
# isolation and durable rows; scale processes/operations for the deployment.
$env:RUBYDB_SERVER_WORKLOAD_PROCESSES = "8"
$env:RUBYDB_SERVER_WORKLOAD_OPERATIONS = "1000"
ruby benchmarks/multiprocess_server_workload.rb

# Real two-engine replication and promotion validation
bundle exec rspec spec/replication_failover_integration_spec.rb
```

The scheduled/manual GitHub Actions workflow `.github/workflows/workload.yml`
also runs the threaded durability, server latency, and multi-process client
workloads and uploads their JSON results as an artifact. Treat those results as
environment-specific evidence, not a universal capacity guarantee.

Archive the JSON output from the soak run with the Ruby version, RubyDB commit,
host resources, and elapsed time. The harness creates a fresh temporary
database for every round and fails if any round loses durable rows.

## Current boundaries

- Embedded databases now require exclusive ownership by one engine. A second
  engine or process opening the same path receives an error. Multiple application
  processes should connect through the server. The adjacent `.lock` file is
  intentionally retained after close; the operating system releases ownership
  on close or process exit. Never delete it while the database is open. This
  requires a filesystem that implements file locking correctly. Hard-linked
  database aliases and shared custom WAL/metadata paths are unsupported.

- Failed metadata publication rolls back the in-memory schema and leaves the
  durable catalog unchanged; callers receive an error and may retry the
  mutation. Exercise disk-full and interrupted-rename fault injection on the
  target filesystem before release.

- Join support currently covers qualified `INNER`, `LEFT [OUTER]`, `RIGHT`, and
  `FULL [OUTER] JOIN` with `ON` predicates. Join reordering is limited to safe
  inner-join plans; correlated subqueries, advanced set-operation ordering,
  and broader dialect-specific SQL still require dedicated compatibility tests.
- The ActiveRecord migration test is intentionally scoped. Complex table
  rebuilds, `change_column`, polymorphic references, generated columns, and
  adapter-specific schema dumps require dedicated compatibility tests before
  relying on them.
- The soak harness and multi-process server workload cover distinct concurrency
  paths, but they do not provide a universal capacity certification; perform
  environment-specific load, crash, and operational recovery testing.
- Failover is manual and requires an operator to confirm the replica is caught
  up and that the old primary is fenced. Automatic leader election is not
  enabled.
- The replica fence covers engine schema, row, branch, vacuum, and compaction
  mutation entry points. Empty-replica catalog bootstrap, transaction-integrated
  replication, and reconnect catch-up are covered; true multi-host partition,
  split-brain, and automated-election validation remain deployment work.

RubyDB reports unsupported features as unsupported rather than advertising CTE
or bulk-alter capability to ActiveRecord.
