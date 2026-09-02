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

The current suite verifies storage reopen, subprocess crash recovery, MVCC isolation/vacuum, durable visibility version-history traversal, constraints including ON DELETE/ON UPDATE referential actions and nullable values, indexes including deep B-tree splits, SQL execution including idempotent database/table/index DDL and SQL foreign-key actions, schema DDL, views, trigger DDL and dispatch, CREATE TABLE, ALTER TABLE column and constraint changes, transaction before-image rollback and SQL savepoints, and VACUUM, live TCP sessions, TLS transport, password/SCRAM authentication and authorization, metrics updates including Prometheus export, liveness/readiness health reporting through the server request router, live CLI doctor checks with safe repair behavior, truthful CLI status reporting, live CLI branch diff/merge/checkout operations, live CLI inspection values, live CLI snapshot creation/listing and vacuum reporting, live CLI backup creation and restore dry-run validation, live CLI database creation and deletion, the documented SQL compatibility contract, full/snapshot/incremental/differential backup validation, logical replication, durable replica state, guarded failover promotion, durable fencing epochs, recovery resource checks, migration/schema-diff behavior including executable migration SQL serialization, atomic branch checkout, branch state/diff/merge behavior, foreign-key integrity lookup behavior, compound/null/boolean check-constraint evaluation, lock conflict/wait/timeout behavior, complete deadlock cycle detection and victim rollback delegation, concurrency mutex initialization, Rails schema-builder SQL generation including defaults and foreign-key conventions, engine block-based table creation, adapter schema dumps preserving primary keys and defaults, release configuration, upgrade guards, benchmark execution, standalone SCRAM verification, actual WAL checkpoint sizing, and deployment artifact checks (152 examples, 0 failures at the latest audit).

## Known limitations

- The concurrent workload verifies parallel writes and durable reopen reads. Immediate point reads interleaved with simultaneous inserts still need a dedicated race fix and regression coverage before RubyDB can claim general concurrent read/write workload certification.

- incremental backups capture WAL mutations after a verified base LSN; differential backups capture the verified base-relative WAL delta and restore through the same validated delta path
- replication is limited to the explicit logical row-mutation envelope API
- automatic failover is limited to synchronized candidates; fencing requires a shared durable fence path and still needs multi-host split-brain validation
- SQL compatibility is narrower than PostgreSQL or SQLite
- production CA lifecycle, performance, and large-scale workload behavior still require dedicated validation
- branch state application and live target-branch merges are supported through the engine reconciliation hook

## Unsupported SQL

The supported dialect is defined in [docs/sql/compatibility.md](../sql/compatibility.md) and enforced by parser/execution integration coverage. RubyDB does not claim PostgreSQL or SQLite compatibility beyond that documented subset.

## Durability guarantees

WAL framing, reopen behavior, subprocess crash-recovery scenarios, actual checkpoint sizing, and fail-closed visibility-map loading are tested. This is not a substitute for production fault-injection and filesystem-specific validation.

## Transaction guarantees

Transaction commit/rollback, MVCC visibility, snapshot isolation behavior, and vacuum safe-point handling are covered by focused tests. High-contention workload validation remains outstanding.

## Isolation guarantees

Read committed, repeatable read, and serializable conflict behavior are covered by focused tests; broader workload and distributed-isolation validation remains outstanding.

## Backup guarantees

Full compressed backups restore into a fresh directory and checksum tampering is detected. Incremental and differential backups validate the base, checksum the change set, and apply WAL row mutations during restore. Production-scale backup-chain and filesystem fault-injection testing remains outstanding.

## Replication guarantees

Logical row-mutation streaming, LSN deduplication, acknowledgments, acknowledged-LSN reporting, synchronized-candidate promotion verification, and stale-primary rejection through durable fencing epochs are tested. Multi-host fencing and split-brain recovery still require dedicated validation.

## TLS guarantees

TLS 1.2 or newer is enforced when enabled. Certificate/key parsing, CA-file validation, TLS client connections, and the end-to-end SSL transport path are tested. Mutual TLS is configurable through client certificates; certificate rotation and production CA lifecycle procedures remain operational work.

## Security model

Password and SCRAM-SHA-256 authentication, server-signature verification, read/write authorization, and startup validation of incomplete auth configuration are tested through the server/session path.

## Performance characteristics

The repository includes a deterministic storage benchmark (`RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb`) and a concurrent write/durability workload (`ruby benchmarks/concurrent_workload.rb`). Both emit machine-readable JSON. Production-scale throughput, WAL, checkpoint, and concurrency targets still require workload-specific baselines.

## Deployment requirements

The project currently needs:

- a validated Ruby support matrix
- a release-hosted gem/package source (the repository currently uses placeholder project URLs)
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

RubyDB is a promising database project with excellent architectural intent, but it does not yet meet the bar for production use with real data.
