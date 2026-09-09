# RubyDB current-state audit

> This document is a dated architecture audit, not a statement that every
> finding remains open. For current validation evidence, see
> [production validation](../production_validation.md) and the latest CI runs.

## Executive summary

RubyDB is a broad database project with integrated storage, WAL, MVCC,
transactions, catalog, security, server, replication, backup, Rails, and
monitoring paths. The implementation now has substantial focused validation,
but several deployment-level capabilities remain environment-specific or
intentionally bounded.

The primary risk is not that the code is absent; it is that multiple components exist without being integrated into a consistent, correct, durable engine. Existing code needs additional hardening before it can safely store user data.

## Repository audit

### Runtime and package state

- Ruby runtime in the development container: Ruby 3.4.7
- Package metadata targets Ruby >= 3.3.0; CI covers Ruby 3.3 and 3.4 on Linux,
  macOS, and Windows.
- The top-level library entrypoint and gem packaging are covered by
  `require "rubydb"` and release-artifact tests.
- The project uses Bundler and RSpec as the base test stack.
- The repository is organized around a large `lib/rubydb` module tree and includes docs, examples, chaos, and fuzz directories.

### Architectural reality

The project already contains modules for:

- storage engine and page manager
- buffer pool and file management
- WAL and recovery components
- transactions and MVCC
- catalog, indexes, and constraints
- SQL parser and planner
- server and protocol layers
- security and authorization
- replication, backups, and monitoring
- Rails integration

The remaining risk is uneven validation breadth: many capabilities are proven
by focused tests, but multi-host operations, capacity limits, and complete
external-database dialect compatibility are not yet certified.

## High-risk findings

### 1. Library loading (resolved)

The standard Ruby consumer path is now tested:

```ruby
require "rubydb"
```

Release metadata and the local gem build verify that this loads correctly.

### 2. Storage layer (partially resolved)

The storage engine now has page validation, corruption detection, WAL/recovery,
fsync paths, restart tests, subprocess crash tests, filesystem fault injection,
and compaction/reopen coverage. Real disk-quota and power-loss validation on
deployment filesystems remains open.

### 3. Transaction and MVCC semantics (validated foundation)

The transaction manager and visibility map exist, transaction rollback restores
update/delete before-images, and read-committed, repeatable-read, serializable
conflict, deadlock, and concurrency workload paths have regression coverage.
Distributed isolation and deployment-specific contention limits remain open.

### 4. SQL engine is a documented subset

The parser, planner, and executor are covered through end-to-end tests for the
documented RubyDB SQL subset, including joins, aggregates, CTEs, subqueries,
set operations, upserts, and window functions. A common SQLite-style profile
is tested for new Ruby/Rails applications; full PostgreSQL/MySQL/SQLite dialect
and file-format compatibility remains intentionally out of scope for this
phase.

### 5. Security (validated foundation)

Authentication, TLS, SCRAM, authorization, framing limits, deadlines, and
resource-limit startup checks are tied to server/query execution and tested.
An independent security review and production certificate/secret lifecycle
validation remain open.

### 6. Production posture is intentionally bounded

The README and production documents now distinguish tested behavior from
deployment work. RubyDB still needs environment-specific capacity, filesystem,
multi-host failover, certificate lifecycle, and independent security validation
before broader production claims are appropriate.

## Current production posture

RubyDB is best understood as:

- a serious Ruby database foundation with repeatable local validation,
- suitable for controlled workloads within the documented feature set,
- not a drop-in general-purpose database or automatic high-availability service.

The correct short-term operating posture is to treat the project as a pre-production, high-potential codebase that needs disciplined validation and narrower, correctness-first milestones.

## Immediate action items

1. Run the hosted Ruby/Rails/OS compatibility matrix and retain its evidence.
2. Validate real disk quota, power-loss, and filesystem behavior on deployment targets.
3. Validate multi-host partition, split-brain, fencing, and operator failover procedures.
4. Complete an independent security review and certificate/secret rotation drill.
5. Implement or intentionally reject unsupported features with explicit errors.
6. Establish workload-specific capacity baselines and release sign-off records.

The latest local audit passed 270 examples with zero failures. Hosted matrix,
container, filesystem quota/power-loss, multi-host fencing, and independent
security-review evidence must still be retained for a production deployment.

## Conclusion

RubyDB has a substantial production-oriented foundation and repeatable local
validation. Operators must stay within the documented feature set and complete
deployment-specific capacity, filesystem, security, and multi-host failover
validation before entrusting critical data to it.
