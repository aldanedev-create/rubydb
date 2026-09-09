# RubyDB developer guide

This is the implementation guide for contributors who need to change RubyDB
safely. It explains the repository, the request path, the storage invariants,
the test strategy, and the debugging workflow. Read it together with the
topic specifications under `spec/`; the specifications are the behavioral
contract, while this guide explains how the pieces fit together.

## 1. Scope and support promise

RubyDB is a Ruby-native relational database with two ownership modes:

* embedded mode, where one Ruby process owns a database directory; and
* server mode, where the server owns the directory and application processes
  use the client protocol.

The supported surface is the behavior exercised by the test suite and listed
in [SQL compatibility](sql/compatibility.md). Similar syntax does not imply
complete PostgreSQL, MySQL, or SQLite compatibility. A change that broadens
syntax must also specify its semantics, errors, types, transactions, and
adapter behavior.

## 2. Repository orientation

The important directories are:

| Path | Responsibility |
| --- | --- |
| `lib/rubydb` | Engine, SQL, storage, transactions, server, client, adapters |
| `spec` | Unit, integration, protocol, SQL, recovery, and adapter contracts |
| `benchmarks` | Repeatable throughput and concurrency measurements |
| `scripts` | Soak tests, durability drills, fuzzing, and release checks |
| `config` | Example configuration and monitoring rules |
| `examples` | Runnable Ruby and Rails applications |
| `docs` | User, operator, developer, and compatibility documentation |
| `packaging` | Container and deployment examples |
| `exe` and `bin` | Public command-line entry points |

Start with `lib/rubydb.rb` and follow the public API into the engine. For a
feature, locate the nearest existing spec before editing implementation code.
Avoid adding a second abstraction when an existing subsystem already owns the
invariant.

## 3. Local setup

Use a supported Ruby version from the project CI matrix and install the locked
dependencies:

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

Use a temporary database for experiments. Never use a production path in a
test or run a destructive command against an unknown directory:

```ruby
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-dev-") do |dir|
  engine = RubyDB::Storage::Engine.new(File.join(dir, "dev.rdb"))
  engine.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
  engine.close
end
```

The server/client path is required when testing process boundaries. Multiple
independent embedded owners must never open the same database directory.

## 4. The request lifecycle

A typical SQL request follows this sequence:

```text
Ruby API or client
  -> connection/session and authentication
  -> SQL tokenizer/parser
  -> binder and type/parameter validation
  -> planner and executor
  -> transaction/MVCC read or write set
  -> table/index mutation
  -> WAL append and durable commit
  -> result encoding and protocol response
```

Keep failures at the layer that owns them. Parser errors should not be turned
into storage errors. A failed WAL append must not report a committed schema or
row change. A client timeout must not silently convert an unknown commit into
a rollback; the caller must be able to determine whether a request was
committed before retrying.

## 5. Storage and durability invariants

The storage directory contains data pages, metadata, WAL state, and recovery
artifacts. Changes must preserve these invariants:

1. A page has valid framing and checksum before it is trusted.
2. WAL records are validated before replay and are applied in LSN order.
3. A commit acknowledgement is emitted only after the configured durability
   point has succeeded.
4. Schema publication and its dependent indexes are visible atomically.
5. Recovery is idempotent: replaying a committed record does not duplicate a
   row or corrupt an index.
6. Torn, truncated, or corrupted input fails closed with a useful error.
7. Temporary files are not mistaken for a completed checkpoint or backup.

When changing page layout or record encoding, update the format specification,
versioning/upgrade path, compatibility tests, and recovery fixtures. Do not
silently reinterpret old bytes. If a format cannot be read, return an explicit
upgrade or corruption error and preserve the original files for diagnosis.

## 6. WAL, checkpoints, and recovery

The WAL is the source of truth between checkpoints. A checkpoint copies safe
state to durable pages and advances the recovery boundary only after all
required data and metadata have been flushed. Recovery should:

1. open the directory read-only where possible;
2. validate metadata and the last known checkpoint;
3. scan WAL frames, stopping only at a valid end boundary;
4. reject checksum, sequence, length, or transaction inconsistencies;
5. replay committed work and discard incomplete transactions;
6. rebuild or validate indexes before accepting writes; and
7. publish a recovery result with the replayed LSN and warnings.

Tests must cover normal reopen, a process terminated during a write, an
interrupted checkpoint, truncated WAL, invalid checksums, missing metadata,
full-disk behavior, and restore into a new directory. Fault injection belongs
around filesystem calls, not only around Ruby methods, because failures occur
at `fsync`, rename, allocation, and close boundaries.

## 7. Transactions, MVCC, and locking

Every statement executes in a transaction context, whether it is explicit or
implicit. The context owns the snapshot, read view, write set, lock state,
savepoints, and commit result. A transaction must not leak locks or snapshots
when it raises, times out, is cancelled, or loses its connection.

MVCC readers use a stable visibility point. Writers create new versions and
retain the before-image needed by active readers and rollback. Vacuum may
reclaim a version only after the global safe point has passed it. A new feature
must define behavior for:

* read committed, repeatable read, and serializable transactions;
* concurrent update of the same row;
* unique and foreign-key conflicts;
* deadlock detection and victim rollback;
* lock wait timeouts and request cancellation; and
* commit acknowledgement followed by client disconnect.

Deadlock resolution must abort a complete victim transaction, release all of
its locks, and leave other transactions able to progress. Never fix a deadlock
by globally disabling locking or by releasing a lock without undoing the
corresponding write set.

## 8. SQL implementation workflow

For a new statement or expression:

1. write the syntax and semantic contract in `spec/sql`;
2. add parser acceptance and rejection examples;
3. add binder/type/nullability behavior;
4. add planner and executor tests;
5. test transaction, constraint, index, and error interactions;
6. test the Ruby API and server protocol path; and
7. test the ActiveRecord-generated SQL when the feature is adapter-visible.

Prefer parameter binding to string interpolation. Every expression needs
defined behavior for `NULL`, booleans, numeric coercion, text comparison,
collation, and invalid input. Every DDL operation needs idempotence or an
explicit error contract. Every optimizer rewrite must have a semantic
equivalence test against the non-optimized execution path.

The documented common SQLite-style profile is intentionally narrower than
SQLite itself. Do not label a feature “SQLite compatible” until its syntax,
results, types, error behavior, and migration behavior are tested.

## 9. Tables, indexes, and constraints

Table mutations and index mutations are one logical operation. If an index
write fails, the statement must fail visibly and the transaction must either
roll back or retain a recoverable pending state; it must not acknowledge a row
that cannot be found by a required index.

For each index type, test empty and populated tables, duplicate keys, `NULL`,
deep splits, reopen, recovery replay, deletion/merge, and concurrent readers.
For each constraint, test direct SQL, prepared parameters, ActiveRecord
inserts/updates, rollback, and the exact error class/message contract where
callers may depend on it.

## 10. Server, client, and wire protocol

The server is the single owner of the database directory. A client session
handles authentication, capability negotiation, request IDs, deadlines,
cancellation, result framing, and connection shutdown. Protocol changes must
be backward-compatible or carry an explicit protocol version and rejection
path.

Wire cancellation is part of correctness. A cancelled request must stop
execution at safe checkpoints, release transaction resources, and return a
definitive cancellation response. If cancellation races with commit, the
server must preserve the commit outcome and expose enough request identity for
the client to query status rather than blindly retrying.

Test malformed lengths, unknown message types, duplicate request IDs, partial
frames, client disconnects, server shutdown, timeout races, authentication
failure, TLS negotiation, and cancellation during a long scan.

## 11. Rails and adapter work

The ActiveRecord adapter translates Rails schema and query APIs into RubyDB
SQL. Adapter code must preserve Rails expectations for quoting, bind
parameters, affected-row counts, last-insert IDs, transactions, savepoints,
schema introspection, migration versions, and exceptions.

When changing adapter behavior, run the example app and test at least:

* `where`, ordering, limits, scopes, joins, and aggregate relations;
* eager loading, nested associations, and inverse relationships;
* connection pools with multiple threads;
* schema dump/load and populated-table migrations;
* rollback, retry, and migration checksum behavior; and
* every supported Ruby/Rails combination in CI.

The adapter is not proof of complete SQLite or PostgreSQL compatibility. An
application should run its own generated-SQL and migration suite before a
cutover.

## 12. Testing pyramid

Use the smallest test that proves the invariant:

* unit specs for parsing, encoding, types, and isolated algorithms;
* component specs for storage, WAL, indexes, transactions, and protocol;
* integration specs for engine-to-SQL and server-to-client behavior;
* process specs for crash recovery, pooling, and failover;
* workload tests for sustained concurrency and resource limits; and
* example applications for real Rails and Ruby workflows.

Useful commands include:

```sh
bundle exec rspec
bundle exec rspec spec/sql spec/storage spec/transactions
ruby scripts/durability_drill
ruby scripts/production_soak
ruby scripts/fuzz
RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb
```

Record the Ruby version, commit, OS, command, seed, database configuration,
and artifact paths for every non-trivial run. A green unit suite does not
replace a restore drill, multi-process soak, or deployment test.

## 13. Debugging a failing change

Start with [Debugging RubyDB](debugging.md). Reproduce on a fresh temporary
directory, reduce the schema and SQL, rerun with the reported seed, and save
logs plus the WAL metadata. Compare embedded and server/client execution when
ownership or protocol is suspected. Use [Troubleshooting](troubleshooting.md)
for operator symptoms and evidence-preserving recovery steps.

Never “repair” a failing test by deleting WAL, disabling checksums, loosening a
constraint, or turning off synchronization. Preserve the failing directory,
copy it, and investigate the copy.

## 14. Performance and capacity work

Benchmark one variable at a time and report latency percentiles, throughput,
concurrency, payload shape, cache size, WAL/checkpoint settings, and storage
medium. Track p50, p95, p99, error rate, lock wait time, WAL growth, checkpoint
duration, memory, file descriptors, and CPU.

Capacity limits are workload-specific. A benchmark result is not a guarantee
for a Rails application with different indexes, query shapes, or connection
pool settings. Add a regression threshold only after the benchmark is stable
across repeated runs and environments.

## 15. Safe contribution checklist

Before opening a pull request:

1. Explain the invariant and compatibility impact.
2. Add focused tests, including failure paths.
3. Run the relevant focused suite and the full suite.
4. Run formatting/lint and `git diff --check`.
5. Update the appropriate spec and user/operator documentation.
6. Note migrations, format changes, recovery implications, and rollback plan.
7. Include benchmark or soak evidence for hot-path and concurrency changes.
8. Remove debug output, secrets, temporary data, and generated artifacts.

See [Contributing](../CONTRIBUTING.md), [testing](contributing/testing.md),
and [release process](contributing/release-process.md) for the repository
workflow.

