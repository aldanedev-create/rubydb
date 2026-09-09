# RubyDB lessons learned

This page records the engineering lessons from hardening RubyDB. Each lesson is
paired with the rule it creates and the validation that protects it. New
features should update this page when they change an operational guarantee.

## Correctness before breadth

An implemented parser branch, adapter method, or replication class is not a
production feature until it is exercised end to end. A narrow, explicit
compatibility contract is safer than accepting syntax with incomplete
semantics.

Rule: document supported behavior and fail closed for unsupported behavior.
Validation: integration specs and the SQL compatibility documents must agree.

## Durability is a sequence, not a boolean

“Write succeeded” and “data is durable” are different outcomes. WAL ordering,
flush errors, atomic metadata publication, checksums, recovery, and restore must
be tested together. A successful in-memory mutation cannot hide a failed
publication or sync.

Rule: never report a durable acknowledgement before the required WAL and file
operations succeed. Preserve uncertain state for recovery instead of guessing.
Validation: filesystem fault injection, crash recovery, compaction/reopen, and
backup/restore drills.

## Ownership must be explicit

An embedded file cannot safely be opened by multiple independent application
processes merely because each process has a mutex. The operating-system lock and
the server boundary are part of the data-safety model.

Rule: one embedded owner; multiple processes use the server/client topology.
Validation: duplicate-open rejection, process workloads, and connection-limit
tests.

## Replication needs fencing before election

Replica catch-up alone does not prevent two writers. Promotion requires a
known recovery point, durable fencing, stale-writer rejection, and operator
evidence. Automatic election without an independent fencing authority can turn
a network partition into split-brain writes.

Rule: keep automatic election disabled until multi-host fencing is independently
validated in the deployment environment.
Validation: process replacement, TCP partition/healing, stale-primary rejection,
and a real multi-host drill.

## Cancellation must reach the wire and the executor

A client-side timeout that only stops waiting does not stop database work. The
server must keep reading control frames, mark the active request cancelled, and
the executor must check cooperatively during long operations.

Rule: test cancellation as an in-flight protocol event, not as a mocked timeout.
Validation: the production soak sends a real cancel frame and checks the server
request lifecycle.

## Deadlock recovery belongs to transaction ownership

Detecting a cycle is insufficient if the chosen victim is not rolled back and
its locks are not released. The lock manager and transaction manager must share
the same victim identity and lifecycle.

Rule: every resolved deadlock has a victim, rollback, lock release, and a
retryable error for the victim.
Validation: the two-transaction cycle specs and the production soak.

## Adapters are compatibility products

ActiveRecord compatibility includes schema introspection, quoted identifiers,
binds, associations, eager loading, migrations, schema dumps, connection pools,
and error behavior. Passing one CRUD example is not Rails compatibility.

Rule: test the adapter against every supported Rails version and a populated
schema, not only an empty database.
Validation: the Rails matrix and adapter integration suite for Rails 7.1, 7.2,
and 8.0.

## Operations are part of the implementation

Backups, restore destinations, monitoring thresholds, certificate rotation,
secret storage, upgrade rollback, incident preservation, and release evidence
are not afterthoughts. Operators need safe commands and clear stop conditions.

Rule: every destructive or irreversible operation must have a dry run, a backup
boundary, and a documented recovery path.
Validation: the production runbook, restore drill, alert rules, and release
preflight.

## Evidence must be reproducible

Test counts without the commit, runtime, platform, workload, seed, and result
artifact are difficult to trust or reproduce.

Rule: archive machine-readable workload output and record commit, Ruby/Rails
versions, OS, resources, seed, latency percentiles, recovery time, and RPO/RTO.
Validation: CI artifacts, bounded fuzz seeds, benchmark output, and release
checklists.

## Security claims require a separate review

Passing authentication and TLS tests does not review deployment identity,
filesystem permissions, secret lifecycle, dependency exposure, or incident
response.

Rule: treat the repository security suite as a baseline and require an
independent review before sensitive or regulated workloads.
Validation: dependency audit, CodeQL, TLS/auth tests, deployment review, and
credential/certificate rotation drills.
