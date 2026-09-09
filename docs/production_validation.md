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
- Two-engine logical replication of an insert followed by explicit, manual
  promotion of the synchronized replica. Promotion retains the replicated row
  and starts a fenced primary listener. Replicas reject local engine mutations
  while allowing the internal logical replay path; explicit promotion restores
  local writes. Replication TCP input is newline-frame buffered, rejects
  oversized incomplete frames, bootstraps a new replica's catalog before row
  replay, and persists the replay position before ack.
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
  `FULL [OUTER] JOIN` with `ON` predicates. Join reordering, correlated
  subqueries, window frames, and advanced set-operation ordering are not
  release-validated.
- The ActiveRecord migration test is intentionally scoped. Complex table
  rebuilds, `change_column`, polymorphic references, generated columns, and
  adapter-specific schema dumps require dedicated compatibility tests before
  relying on them.
- The soak harness uses threads against one embedded engine. It does not prove
  multi-process writer safety or provide a capacity certification; perform
  environment-specific load, crash, and operational recovery testing.
- Failover is manual and requires an operator to confirm the replica is caught
  up and that the old primary is fenced. Automatic leader election is not
  enabled.
- The replica fence covers engine schema, row, branch, vacuum, and compaction
  mutation entry points. Catalog bootstrap is now covered for an empty replica,
  but this is not a substitute for partition testing, transaction-integrated
  replication, or automated election validation.

RubyDB reports unsupported features as unsupported rather than advertising CTE
or bulk-alter capability to ActiveRecord.
