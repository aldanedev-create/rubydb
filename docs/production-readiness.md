# Production-readiness audit

## Status

RubyDB has verified production-oriented foundations, but it is not yet a general-purpose production database. Supported behavior is backed by the RSpec suite in `spec/`.

## Implemented features

The repository contains substantial scaffolding for:

- page-based storage
- buffer pool caching
- file and page management
- WAL, recovery, and checkpoint modules
- transactions and MVCC abstractions
- SQL parser/planner infrastructure
- server, protocol, and connection components
- authentication and authorization modules
- backup and replication APIs
- monitoring and metrics interfaces
- Rails integration adapters
- ordered, locked migrations with durable version/checksum tracking

## Tested features

The current suite verifies storage reopen, subprocess crash recovery, MVCC isolation/vacuum, durable visibility version-history traversal, constraints including ON DELETE/ON UPDATE referential actions and nullable values, indexes including deep B-tree splits, SQL execution including idempotent database/table/index DDL and SQL foreign-key actions, schema DDL, views, trigger DDL and dispatch, CREATE TABLE, ALTER TABLE column and constraint changes, transaction before-image rollback and SQL savepoints, and VACUUM, live TCP sessions, TLS transport, password/SCRAM authentication and authorization, metrics updates including Prometheus export, liveness/readiness health reporting through the server request router, live CLI doctor checks with safe repair behavior, truthful CLI status reporting, live CLI branch diff/merge/checkout operations, live CLI inspection values, live CLI snapshot creation/listing and vacuum reporting, live CLI backup creation and restore dry-run validation, live CLI database creation and deletion, the documented SQL compatibility contract, full/snapshot/incremental/differential backup validation, logical replication, durable replica state, guarded failover promotion, durable fencing epochs, replication peer-token authentication, recovery resource checks, migration/schema-diff behavior including executable migration SQL serialization and changed-migration detection, atomic branch checkout, branch state/diff/merge behavior, foreign-key integrity lookup behavior, compound/null/boolean check-constraint evaluation, lock conflict/wait/timeout behavior, complete standalone and transaction-manager deadlock cycle detection with victim rollback, concurrency mutex initialization, Rails schema-builder SQL generation including defaults and foreign-key conventions, engine block-based table creation, adapter schema dumps preserving primary keys and defaults, ActiveRecord hash-form ordering and populated-table migration round trips, bounded multi-process workload supervision with child reaping, combined production traffic/deadline/cancellation/capacity/deadlock soak validation, release configuration, release tag/changelog preflight, upgrade guards, benchmark execution, executor query deadlines, wire-level cancellation of in-flight requests, standalone SCRAM verification, actual WAL checkpoint sizing, typed deserialization-corruption detection, preservation of stored false values when defaults are present, filesystem fault injection with descriptor cleanup, compaction/reopen validation, process-level replication failover with stale-writer fencing, and live TCP network-partition catch-up and promotion (268 examples, 0 failures at the latest audit).

## Known limitations

- The concurrent workload and regression suite verify parallel appends, point
  reads, scans, durable reopen reads, multi-process server clients, and a
  process-level replication failover drill. This does not certify universal
  capacity; embedded ownership remains exclusive and multi-process clients must
  use the server.

- multi-row SQL `VALUES` inserts execute through the parser, binder, planner,
  and executor, including per-row conflict handling and Rails insert IDs
- incremental backups capture WAL mutations after a verified base LSN; differential backups capture the verified base-relative WAL delta and restore through the same validated delta path
- replication is limited to the explicit logical row-mutation envelope API;
  process replacement, live TCP partition/catch-up, and same-host fencing are
  tested, while true multi-host partitions and split-brain recovery remain
  deployment work
- automatic failover is limited to synchronized candidates; fencing requires a shared durable fence path and still needs multi-host split-brain validation
- the SQLite compatibility profile covers the documented common application
  surface, but it is not SQLite file-format or extension compatibility
- production CA lifecycle, independent security review, performance targets,
  and large-scale workload behavior still require dedicated validation
- branch state application and live target-branch merges are supported through the engine reconciliation hook

## Unsupported SQL

The supported dialect is defined in [docs/sql/compatibility.md](../sql/compatibility.md) and enforced by parser/execution integration coverage. RubyDB provides a tested common SQLite-style profile, not complete SQLite file-format, extension, pragma, or error compatibility.

## Durability guarantees

WAL framing, reopen behavior, subprocess crash-recovery scenarios, actual checkpoint sizing, fail-closed visibility-map loading, filesystem fault injection, compaction/reopen behavior, networked replication failover, and verified restore drills are tested. This is not a substitute for real quota, power-loss, and filesystem-specific validation.

## Transaction guarantees

Transaction commit/rollback, MVCC visibility, snapshot isolation behavior, and vacuum safe-point handling are covered by focused tests. High-contention workload validation remains outstanding.

## Isolation guarantees

Read committed, repeatable read, and serializable conflict behavior are covered by focused tests; broader workload and distributed-isolation validation remains outstanding.

## Backup guarantees

Full compressed backups restore into a fresh directory and checksum tampering is detected. Incremental and differential backups validate the base, checksum the change set, and apply WAL row mutations during restore. Production-scale backup-chain and filesystem fault-injection testing remains outstanding.

## Replication guarantees

Logical row-mutation streaming, LSN deduplication, acknowledgments, acknowledged-LSN reporting, synchronized-candidate promotion verification, process replacement, live TCP partition/catch-up, and stale-primary rejection through durable fencing epochs are tested. Multi-host fencing and split-brain recovery still require dedicated validation.

## TLS guarantees

TLS 1.2 or newer is enforced when enabled. Certificate/key parsing, CA-file validation, TLS client connections, and the end-to-end SSL transport path are tested. Mutual TLS is configurable through client certificates; certificate rotation and production CA lifecycle procedures remain operational work.

## Security model

Password and SCRAM-SHA-256 authentication, server-signature verification, read/write authorization, and startup validation of incomplete auth configuration are tested through the server/session path.

## Performance characteristics

The repository includes a deterministic storage benchmark (`RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb`) and a concurrent write/durability workload (`ruby benchmarks/concurrent_workload.rb`). Both emit machine-readable JSON. Production-scale throughput, WAL, checkpoint, and concurrency targets still require workload-specific baselines.

## Deployment requirements

The project currently needs:

- a validated Ruby support matrix
- RubyGems publication credentials (`RUBYGEMS_API_KEY`) configured as a protected
  GitHub Actions secret before pushing a release tag
- a documented operator runbook for backups, upgrades, rollback, and incident preservation
- explicit durability and crash-recovery validation
- secure-by-default configuration development
- a narrower set of supported features documented honestly

## Remaining roadmap items

Main remaining work is to complete the sequence laid out in the repository design:

1. production CA lifecycle and certificate rotation
2. broader SQL compatibility contract and workload benchmarks
3. production-grade failover fencing and broader SQL compatibility
4. operator runbooks and deployment validation

## Bottom line

RubyDB has a validated production-oriented foundation, but it does not yet meet
the bar for unrestricted production use with real data outside its documented
feature set and deployment-specific validation.
