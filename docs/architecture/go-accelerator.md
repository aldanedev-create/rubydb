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
accelerator/internal/runtime/                 request loop and dispatch
accelerator/internal/protocol/                bounded frames and columnar batches
accelerator/internal/execution/               filters, sorting, aggregates, joins
accelerator/internal/storage/                 immutable snapshot page reads
accelerator/internal/wal/                     checksums, compression, record batches
accelerator/internal/parallel/                 bounded queues and worker scheduling
accelerator/internal/memory/                  reusable arena and byte buffers
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

Future shared immutable page snapshots and broader index/parallel operators
must preserve the same contract: Go may read a versioned snapshot, but it may
never mutate pages, indexes, catalog files, WAL, transaction state, or
visibility state.
