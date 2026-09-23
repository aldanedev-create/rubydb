# Immutable table export

`rubydb export` writes a stable local-table extract as JSON Lines or CSV. It
is intended for analytics hand-off, support investigation, a migration input,
or a controlled backup-adjacent data export. It is not a replacement for a
verified RubyDB backup: an export contains rows from one table, not WAL,
catalog, branch, user, or restore metadata.

## Quick start

Export every column as JSONL. The output path must not already exist.

```sh
rubydb export \
  --database /var/lib/rubydb/orders.rdb \
  --table orders \
  --format jsonl \
  --out /srv/exports/orders-2026-09-21.jsonl
```

Export a projection and filter to CSV:

```sh
rubydb export \
  --database /var/lib/rubydb/orders.rdb \
  --table orders \
  --columns id,customer_id,total_cents,created_at \
  --where 'status eq "paid"' \
  --format csv \
  --out /srv/exports/paid-orders.csv
```

Set a hard row cap when an export is initiated by an operational workflow with
a known safe size. RubyDB removes the partial file if a later batch would
exceed the cap:

```sh
rubydb export --database data/app.rdb --table audit_events \
  --max-rows 500000 --out exports/audit-events.jsonl
```

Values in `--where` are JSON literals when possible. Quote string literals as
shown above; `true`, `false`, `null`, integers, and decimal JSON numbers do
not need quotes. The supported operators are `eq`, `ne`, `lt`, `lte`, `gt`,
`gte`, `like`, `is_null`, and `is_not_null`. `like` accepts `%` for any
sequence and `_` for one character.

The command understands qualified filter names such as `orders.status`, but
the table name is only stripped for this single-table command. Joins, SQL
expressions, ordering, grouping, and arbitrary SQL are intentionally not
accepted by this exporter. Create a reviewed reporting table or query through
the normal application API for those cases.

## Consistency and safety

The default `--engine auto` choice uses the bundled Go tool when its checksum
is verified. RubyDB takes the storage lock only long enough to reject active
transactions, flush committed pages/visibility/catalog metadata, and create a
private immutable file copy. It releases the lock before Go streams the copy,
so new writers can proceed without changing the export. The temporary snapshot
is SHA-256 checked by Go and deleted on success or failure.

This means an export is a stable committed snapshot, not a moving view of a
table. RubyDB rejects it if the engine has an active transaction or MVCC writer
because a safe immutable visibility boundary cannot be established. Coordinate
with the owning service, retry after it finishes its transaction, or use a
backup/restore workflow for a larger maintenance operation.

Go never opens mutable catalog, WAL, index, or visibility files. It validates
the manifest, file size/hash, page headers, record lengths, flags, and column
counts before decoding rows. A malformed snapshot fails the command; it is not
silently converted into a partial extract.

The output is atomic:

- an existing `--out` file is refused, never overwritten;
- data is written to `OUT.partial` using restrictive permissions;
- the file is flushed and `fsync`ed; and
- it is renamed to `OUT` only after a successful stream.

Do not make the destination directory public. JSONL/CSV files are not
encrypted by RubyDB, may contain personal data, and inherit the access policy
of the destination filesystem or object-store upload process.

## Choosing an engine

`auto` is the normal choice. It selects the checksum-verified Go tool when it
is packaged for the current platform and otherwise uses Ruby. Neither mode
needs a Go compiler on the application host.

```sh
# Require the Go streaming path; useful for release validation.
rubydb export --engine go --database data/app.rdb --table events --out events.jsonl

# Ruby reference implementation; useful for comparison or diagnostics.
rubydb export --engine ruby --database data/app.rdb --table events --out events-ruby.jsonl
```

The project’s tests compare Ruby and Go JSONL byte-for-byte for projection,
filtering, booleans, floats, timestamps, and binary data. Use `--engine go`
only after building or installing a release containing the current platform
tool. If that explicit mode cannot find a verified tool, it fails rather than
claiming Go acceleration. `auto` safely falls back to Ruby.

The Ruby reference path holds the engine read lock while it writes, so use it
for parity checks, recovery diagnostics, or small exports. For a large export
on a busy service, require the verified Go path and validate it in staging.

## Format rules

JSONL has one deterministic JSON object per line; field order follows
`--columns` or schema order. CSV has an LF-terminated header and follows the
same column order. Both use the following portable representations:

| RubyDB value | JSONL / CSV representation |
| --- | --- |
| `NULL` | JSON `null`; empty CSV cell |
| `BLOB` | base64 string |
| `DECIMAL` | exact decimal string |
| `DATE` | ISO date (`YYYY-MM-DD`) |
| `TIMESTAMP` | UTC RFC 3339 seconds |
| `TIME` | fixed six-digit UTC time representation |
| `JSON` | JSON value in JSONL; serialized JSON in CSV |
| `NaN`, infinities, negative zero | strings `NaN`, `Infinity`, `-Infinity`, `-0` |

CSV cannot retain all RubyDB types without a convention. Prefer JSONL if a
consumer needs type-safe replay. Verify consumers decode base64 blobs and
decimal strings deliberately instead of allowing language defaults to coerce
them.

## Performance validation

The export path streams pages and batches. It does not materialize every Go
row in Ruby, so a multi-million-row extract has bounded Go batch memory plus
the output buffer. Snapshot creation still requires temporary disk space about
the size of the database file. Monitor free space and set destination quotas
before large exports.

Compare Ruby and Go on the target machine; do not assume a speedup from a
different storage device or query shape:

```sh
RUBYDB_EXPORT_ROWS=10000 RUBYDB_EXPORT_SAMPLES=3 \
  ruby -Ilib benchmarks/snapshot_export.rb

# Release-sized test; save the JSON report with the release evidence.
RUBYDB_EXPORT_ROWS=1000000 RUBYDB_EXPORT_SAMPLES=5 \
  ruby -Ilib benchmarks/snapshot_export.rb > export-benchmark.json
```

The report includes p50/p95/p99 latency, rows/sec, bytes, and RSS when the host
can expose it. The benchmark compares the completed Ruby and Go export runs;
it does not invent worker fallback or restart counters. Collect those from
the server/accelerator metrics for a long-running deployment. Run `--engine ruby`
and `--engine go` against representative data, compare row counts and hashes,
and keep both reports in the deployment record.
