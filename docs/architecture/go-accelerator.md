# Ruby + Go accelerator

RubyDB installs as one Ruby package. Release gems include CGO-free Go
executables for Windows amd64/arm64, Linux amd64/arm64, and macOS amd64/arm64. A
developer needs Go only when building RubyDB itself or publishing a release;
an application developer or production operator does not need Go installed.

Ruby remains the database authority. It owns SQL meaning, physical-plan
selection, transactions, MVCC visibility, locks, schema and constraints,
permissions, WAL, recovery, and every commit decision. Go receives immutable
read batches and returns data; it never writes database pages or decides what
is committed.

## Runtime boundary

The Ruby process starts one long-lived private worker over stdin/stdout. The
worker does not listen on a TCP port and is not reachable by application
clients.

```text
application -> RubyDB parser/planner -> Ruby transaction and visibility checks
                                      \-> Go binary read worker
Ruby storage/WAL/MVCC/commit <--------- Ruby remains authoritative
```

The Go source is deliberately split by responsibility:

```text
accelerator/cmd/rubydb-accelerator/main.go   process entrypoint only
accelerator/cmd/rubydb-tools/main.go         one-shot verified maintenance tools
accelerator/internal/runtime/                 request loop and dispatch
accelerator/internal/protocol/                bounded frames and columnar batches
accelerator/internal/execution/               filters, sorting, aggregates, joins
accelerator/internal/storage/                 immutable snapshot page reads
accelerator/internal/wal/                     checksums, compression, record batches
accelerator/internal/parallel/                 parallel chunk scheduling
accelerator/internal/metrics/                 operation counts and p95 timings
```

Each package has focused tests. The storage reader accepts only a page size,
page list, and an immutable snapshot contract supplied by RubyDB; it does not
open the catalog, WAL, or mutable page state by itself. This boundary is
intentional: adding more Go code must not silently create a second transaction
or recovery authority.

Control messages use bounded JSON-lines. Large row operations use a versioned
`RDBB` binary frame with a columnar batch: column names are sent once and
values use typed, length-prefixed fields for NULL, booleans, integers, floats,
strings, bytes, and JSON fallback values. Responses contain bounded metadata
and one or more columnar result batches. This removes the old JSON/base64 row
copy from the hot path while retaining a simple control protocol.

Every frame has a request ID, protocol/version fields, a maximum size, and a
structured error status. Startup verifies the binary against `SHA256SUMS`.
Timeout, EOF, protocol mismatch, checksum failure, malformed data, or worker
exit stops that worker. In `auto`, Ruby retries the operation on the Ruby
executor; in `required`, the error is surfaced to the caller.

## Accelerated work

The current safe physical operators are:

- immutable snapshot page and record decoding for eligible read-only scans;
- immutable B-tree entry filtering for eligible indexed scans;
- columnar serialization and deserialization;
- deterministic parallel filtering for large batches;
- filtering, projection, ordering, DISTINCT, and NULL-aware comparisons;
- grouped `COUNT`, `SUM`, `AVG`, `MIN`, and `MAX`;
- validated inner hash and merge joins;
- portable `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, `LEAD`, and aggregate window operations;
- SHA-256 checksums; and
- gzip archive compression/decompression;
- versioned WAL batch encoding, checksums, and optional compression; and
- request-scoped cancellation, multiplexed requests, and bounded JSON result batches.

WAL acceleration is deliberately a preparation boundary: Ruby assigns the
transaction ID, LSN, commit order, and commit decision. Go returns an encoded
and checksummed batch; Ruby is still responsible for writing the approved
bytes, calling `fsync`, and publishing the durable acknowledgement. A failed
or uncertain acknowledgement must remain a Ruby recovery error.

The SQL executor delegates only plans it can describe with simple identifiers,
literal predicates, and an eligible immutable read snapshot. Outer joins,
complex expressions, writes, active transactions, and visibility-sensitive
work stay in Ruby. The general row pipeline can also receive explicit
projection, DISTINCT, HAVING, window, and merge-join specifications when the
Ruby planner has already validated their semantics. Ruby applies every stage
that was not delegated and remains the result authority through differential
validation.

### Immutable snapshot contract

Before a snapshot scan Ruby flushes dirty pages, visibility metadata, and the
table catalog while holding the engine lock. The default direct path records
the page size/count, table page lists, schema, B-tree entries, and visibility
exclusions in a manifest, then lets Go read the already-flushed database file
while that lock remains held. This avoids copying and hashing the complete
database for every read. `RUBYDB_ACCELERATOR_DIRECT_SNAPSHOT=off` (or
`accelerator.direct_snapshot: false`) selects the detached fallback: Ruby
copies the database to a short-lived private snapshot, records a SHA-256
digest, and removes the copy after the request. Go verifies the file size,
optional digest, page headers, record bounds, record flags, column count, and
type lengths before returning rows.

This path is intentionally conservative. Ruby declines it while the current
thread has a transaction or any transaction is active. Go does not read WAL,
catalog files, live indexes, or MVCC state and cannot publish writes. If a
manifest, page, index entry, type, or result is invalid, `auto` falls back to
the Ruby executor and `required` reports the error. The B-tree data is a
consistent in-memory index snapshot because RubyDB rebuilds its indexes from
metadata on open; it is not a new persisted index format.

## Automatic selection

The default is:

```yaml
accelerator:
  mode: auto
  read_pipeline: on
  direct_snapshot: true
  min_rows: 256
  # Optional measured break-even points. Omitted workloads use min_rows.
  min_rows_by_workload:
    scan: 1000
    aggregate: 2000
    join: 5000
```

For each eligible snapshot scan, the first automatic operation is differentially
checked against the Ruby implementation and timed. The result is recorded for
both the physical snapshot scan and the row-batch scan family. Aggregate and
join operations retain their own differential checks and timing. Utility
operations record checksum, compression, and WAL-batch samples as well.
`auto` keeps the Go operator only when it is faster and equivalent; otherwise
that family falls back to Ruby for the lifetime of the worker. This avoids
turning IPC overhead into a regression for small or already-optimized queries.
The decision is process-local and is reset on restart, so it must be validated
again after a deployment change.

`mode: required` bypasses the speed decision and is intended for accelerator
CI, release smoke tests, and deployments whose workload benchmark has already
established a win. `mode: off` disables the worker entirely.

```sh
RUBYDB_ACCELERATOR=off rubydb doctor
RUBYDB_ACCELERATOR=required rubydb accelerator --ping --json
```

The runtime reports capabilities, selected mode, checksum-verified binary,
calibration decisions, and the last worker error in `rubydb accelerator
--ping --json` and database statistics.

For Ruby write throughput, use a multi-row SQL `INSERT` or the embedded
`RubyDB.open(...).insert_many` API. RubyDB validates and WAL-logs each row, but
publishes table metadata once for the batch. Inside a transaction it waits for
the durable commit flush, so it does not add an unsafe per-row metadata sync.

## Building and packaging

Release builds are cross-compiled with CGO disabled:

```sh
ruby scripts/build_accelerator
RUBYDB_ACCELERATOR_TARGETS=current ruby scripts/build_accelerator
bundle exec rake build:checksum
```

The gemspec packages the Ruby bridge, source module, six supported binaries,
and the checksum manifest. A release preflight must run Go tests, Ruby
accelerator tests, checksum verification, the extracted-gem handshake, and a
representative workload benchmark before publishing.

## Performance policy

Go is intended to improve workloads dominated by scans, joins, aggregation,
serialization, compression, or checksum work. It cannot promise that every
query becomes seconds instead of minutes: indexes, disk latency, query shape,
lock contention, and result size may dominate. The benchmark harness should
report p50/p95/p99 latency, throughput, rows/sec, an RSS snapshot where the
platform exposes it, worker/fallback metrics, and WAL-batch timing. CPU,
process restarts, and host-level memory should be collected by the deployment
monitor because those metrics are platform-specific. A speed claim is valid
only for the measured workload and platform.

### Which Go packages have a production path?

Use the packages according to the workload instead of enabling every operator
indiscriminately:

| Package | Real benefit | RubyDB usage |
| --- | --- | --- |
| `internal/storage` | Reads immutable pages without converting every page into Ruby objects first | Large read-only snapshot scans and `rubydb export` |
| `internal/execution` | Columnar filtering, projection, sorting, DISTINCT, aggregates, joins, and windows | Large validated batches when differential checking and calibration show a win |
| `internal/protocol` | Typed batches avoid JSON/base64 row transfer | Large accelerator requests; small results stay on the lower-overhead path |
| `internal/parallel` | Bounded read parallelism | Independent pages of an immutable snapshot only |
| `internal/wal` | Encodes, checksums, and compresses approved WAL batches | Preparation only; Ruby still writes, syncs, and acknowledges durability |
| `internal/runtime` | Cancellation, deadlines, lifecycle, and clean restart | Every long-lived worker request |
| `internal/metrics` | Makes worker latency measurable | `rubydb accelerator --ping --json`, calibration, diagnostics, and release benchmarks |

Transactions, MVCC, locks, schema publication, constraints, index authority,
recovery, and commit ordering intentionally remain Ruby-owned. Go code without
a reachable Ruby call site, a correctness test, and a measured workload win is
an internal building block—not a promised runtime feature.

For tiny CRUD requests, point lookups, short writes, network-heavy requests,
or fsync-bound commits, Go can be slower because process/protocol overhead is
larger than the computation. Benchmark the target workload, keep `mode: auto`,
and use `mode: required` only after that deployment establishes a repeatable
win.

## Performance implementation plan

This is the implementation order for reusing the current code before adding
more code. Each phase must pass correctness tests and a representative
benchmark before the next phase is enabled by default.

### Phase 1: make the Ruby baseline fast

Reuse the existing Ruby storage and executor paths first:

1. Keep primary-key, unique-key, and exact foreign-key lookups on the row
   locator and index paths in `lib/rubydb/storage/engine.rb` and
   `lib/rubydb/indexes/`.
2. Keep metadata-only `COUNT(*)`, early `LIMIT`, cached column types, and
   automatic constraint indexes enabled for small and point queries.
3. Add batch insert/update APIs so validation, index maintenance, WAL records,
   and page writes are grouped without weakening commit or `fsync` semantics.
4. Measure Ruby object allocation and avoid converting rows to hashes more
   than once on a Ruby-only request.

The result is the fast path for Rails CRUD, health checks, request lookups,
short transactions, and all writes. Go should not be introduced into these
paths merely because it exists.

Ruby memory and garbage-collection work is part of this phase. The target is
fewer temporary objects, not manually forcing collection during requests:

- keep physical rows in compact internal arrays or tuples until the public
  result needs named columns;
- avoid rebuilding column names, type objects, predicates, and index keys for
  every row;
- stream large scans and use bounded batches instead of materializing a whole
  table;
- reuse serialization, WAL, and protocol buffers only where ownership is
  unambiguous;
- freeze or cache immutable metadata, identifiers, and type descriptors;
- measure allocation and GC time separately from disk and lock time; and
- never trade away transaction isolation, page ownership, or cleanup for object
  reuse.

Ruby optimizations must be benchmarked against the same query and storage
state. A lower allocation count is not sufficient if it changes NULL handling,
ordering, visibility, or recovery behavior.

### Phase 2: reuse the long-lived Go worker for large reads

Use `internal/protocol`, `internal/runtime`, `internal/execution`, and
`internal/parallel` together through the existing Ruby accelerator manager:

1. Ruby validates the plan, snapshot, types, filters, and deadline.
2. Ruby sends one typed columnar batch to the already-running worker.
3. Go scans, filters, sorts, aggregates, joins, or windows in bounded memory.
4. Ruby differentially checks the result during calibration and remains the
   final result authority.
5. The adaptive policy keeps Go only when it is equivalent and faster.

Use this for large read-only scans, joins, aggregation, sorting, DISTINCT,
window functions, and result serialization. Do not start a process per query.

### Phase 3: reuse immutable storage reads

Use `internal/storage` and the snapshot manifest for large scans and exports.
Ruby flushes and publishes an immutable read contract; Go reads pages without
opening mutable catalog, WAL, visibility, or index authority. Keep the Ruby
fallback for unsupported snapshots, corrupted pages, stale manifests, and
small tables.

### Phase 4: reuse Go for write preparation only

Use `internal/wal` and checksum/compression helpers for large approved WAL
batches. Ruby must continue to assign transaction IDs and
LSNs, order commits, own locks, write the approved bytes, call `fsync`, and
publish the durable acknowledgement. Until that complete path is integrated
and crash-tested, these packages remain internal building blocks and are not a
production write-speed claim.

### Phase 5: replace fixed thresholds with measured policy

Maintain separate thresholds for scans, joins, aggregates, sorting, exports,
and result serialization. Record rows, bytes, p50/p95/p99, CPU, memory,
fallbacks, worker restarts, and deadline failures. Calibrate with 10,000,
100,000, and 1,000,000-row workloads on every supported platform. A small
workload must remain on Ruby when IPC cost exceeds the saved computation.

The policy should be operation-specific rather than a single global row
threshold. A point lookup, a 50-row Rails response, a million-row export, and
a grouped join have different break-even points. Record the decision and its
reason so operators can see whether Ruby was selected because the workload was
small, Go was unavailable, the deadline was unsafe, or Ruby was faster.

### Phase 6: remove or quarantine unused code

Every Go package must have all three of these before it is advertised:

- a reachable Ruby call site;
- unit, differential, and failure-path tests; and
- a repeatable benchmark win for a named workload.

Code that does not meet all three conditions stays documented as internal or
is removed during cleanup. It must not increase the gem surface or be called a
production accelerator.

Before adding another Go operator, first ask whether the same benefit can be
obtained by reducing Ruby allocations, using an existing index, batching an
existing WAL path, or improving the planner. New Go code is justified only
when it removes a measured bottleneck that Ruby cannot address economically.

The release checklist must reject duplicate transaction or MVCC
implementations in Go, operators without a Ruby dispatch path, startup-only
benchmarks, and paths without cancellation, memory bounds, corruption
handling, and differential correctness tests.

Future shared immutable page snapshots and broader index/parallel operators
must preserve the same contract: Go may read a versioned snapshot, but it may
never mutate pages, indexes, catalog files, WAL, transaction state, or
visibility state.

## Streaming export tool

`rubydb-tools export` is a bundled one-shot companion executable used by
`rubydb export`. It is intentionally separate from the long-lived worker: an
operator table extract needs a durable file output and a detached immutable
source, while application queries use the private worker protocol.

Ruby creates a SHA-256-protected detached snapshot while it owns the engine
lock, then releases the lock before the tool opens the snapshot read-only. The
tool validates the manifest, source size/hash, page headers, record headers,
column count, and record bounds. It performs page reads in a bounded pool (at
most eight workers), preserves manifest page order, and emits batches directly
to JSONL or CSV rather than sending each row back through Ruby.

The tool is deliberately limited to a single table, unordered page scan, a
projection, and simple filters. It has no ability to open a live database,
consult WAL, mutate any storage file, run arbitrary SQL, or overwrite an
export path. The Ruby fallback is kept as an oracle; release tests compare both
formats byte-for-byte. See [immutable table export](../export.md) for the
operator interface and benchmark gate.
