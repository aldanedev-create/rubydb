# RubyDB production roadmap

## Current baseline

The project has a meaningful repository skeleton and substantial design intent. It already includes modules for storage, indexing, transactions, MVCC, SQL parts, server, replication, and backup flows. However, the implementation still lacks enough end-to-end proof for durable, crash-safe operation.

## Prioritized roadmap

### Phase 0 — Repository stabilization

- fix library loading and Ruby compatibility metadata
- verify the project loads via `require "rubydb"`
- establish a truthful project health baseline
- add characterization tests for current public behavior

### Phase 1 — Storage durability

- define a stable on-disk page format and file format
- add checksums, header validation, and corruption detection
- ensure WAL durability precedes page flush semantics
- add real restart tests and crash tests

### Phase 2 — Transaction correctness

- complete transaction lifecycle handling
- prove commit/rollback semantics under restart
- validate isolation semantics and visibility rules
- add deadlock and lock manager tests

### Phase 3 — Catalog and indexes

- persist catalog metadata consistently
- maintain indexes correctly during DML
- verify index consistency after crash and rollback
- document supported SQL compatibility targets honestly

### Phase 4 — SQL execution and optimizer

- validate end-to-end SQL execution
- ensure binder, planner, and executor are integrated
- add integration tests for basic DML and queries
- implement `EXPLAIN` only with real, honest plan output

### Phase 5 — Server and security

- harden server lifecycle and malformed-client handling
- enforce connection limits and timeouts
- check authorization before execution
- validate auth flows and access controls

### Phase 6 — Backup, recovery, and replication

- prove full backup + restore works from a clean environment
- validate point-in-time or incremental recovery only when implemented correctly
- only add replication once WAL recovery is demonstrably correct

### Phase 7 — Monitoring and production readiness

- add structured logging and health/readiness checks
- expose operational metrics
- create a final production-readiness audit with limitations and unsupported features

## Hard gates before declaring production readiness

RubyDB should not claim production readiness until it demonstrates all of the following:

- updated data survives restart
- crash recovery is validated with subprocess termination tests
- transactions preserve isolation semantics
- WAL ordering is durable and replayed correctly
- index and table data stay consistent
- authZ/authN is enforced over real operations
- backup and restore work in a clean environment
- server operations handle failures safely without whole-process crashes

## Decision rule

The repository must prefer correctness over feature breadth. A smaller well-tested engine is more valuable than a broad but unsafe one.

## Long-term target

The final target is not a fake "PostgreSQL clone" or a marketing demo. The target is a Ruby-first, SQLite-like development experience paired with durable, crash-safe relational database semantics that can be validated under real workloads.
