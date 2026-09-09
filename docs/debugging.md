# Debugging RubyDB

This playbook is for finding defects without destroying the evidence needed
to recover data. Use it in development and staging first. Production
diagnostics must follow the application’s privacy, access, and change-control
policies.

## Debugging principles

1. Reproduce on a copy or a new temporary directory.
2. Identify the layer: API, session, protocol, parser, planner, executor,
   transaction, storage, WAL, filesystem, or deployment.
3. Reduce the input while preserving the failure.
4. Record versions, configuration names, seed, timing, and request IDs.
5. Add a regression test before changing behavior.

A database that returns an error is often safer than one that silently repairs,
retries, or acknowledges unknown state. Keep fail-closed behavior intact while
diagnosing.

## Reproducible diagnostic baseline

```sh
git rev-parse HEAD
ruby -v
bundle exec ruby -Ilib exe/rubydb --version
bundle exec rspec --format progress
git diff --check
```

Use a fresh directory for each reproduction. Save the command and, for random
or concurrent tests, the seed:

```sh
RUBYDB_FUZZ_SEED=12345 RUBYDB_FUZZ_ITERATIONS=1000 ruby scripts/fuzz
bundle exec rspec spec/path/to/failing_spec.rb:42 --format doc
```

## CLI inspection

The CLI is the first diagnostic interface:

```sh
bundle exec ruby -Ilib exe/rubydb status --config config/rubydb.yml
bundle exec ruby -Ilib exe/rubydb doctor --config config/rubydb.yml
bundle exec ruby -Ilib exe/rubydb inspect --config config/rubydb.yml
bundle exec ruby -Ilib exe/rubydb shell --config config/rubydb.yml
```

Use `status` for ownership, lifecycle, and health; `doctor` for non-destructive
checks and safe repairs; and `inspect` for metadata, schema, WAL, and storage
facts. Capture JSON output when the command supports it so an incident can be
compared over time. Read [CLI guide](cli.md) before using maintenance commands.

## Logging and safe verbosity

Use the normal structured logs first. Increase verbosity only for a bounded
reproduction. `--verbose` is useful for CLI execution, while `RUBYDB_DEBUG=1`
enables development backtraces in command wrappers. Debug logs can contain SQL
shapes, paths, identifiers, and timing; they must be access-controlled and
sanitized before sharing.

When adding logs, include stable fields such as request ID, transaction ID,
connection ID, LSN, operation, duration, and outcome. Never log passwords,
SCRAM secrets, bearer tokens, private keys, or unredacted customer values.

## Layer isolation

### API versus engine

Run the same operation through the direct Ruby API and the server/client path.
If only server mode fails, inspect protocol framing, authentication, session
state, serialization, and timeout handling. If both fail, reduce to engine SQL
and storage.

### Parser versus executor

First parse/bind a statement without committing data. Then execute it against a
minimal schema. A parser failure should identify token position and expected
construct. A binder failure should identify parameter count/type context. An
executor failure should preserve transaction rollback and identify the table,
index, or constraint involved.

### Planner versus semantics

Compare an optimized plan with a simple scan where possible. Verify row IDs,
duplicates, `NULL`, ordering, grouping, and snapshot visibility. Optimizer
changes require equivalence tests, not only performance numbers.

### Storage versus filesystem

Test the storage operation with a real temporary filesystem first. Then inject
failures at write, flush, rename, allocation, and close boundaries. A Ruby
exception around a filesystem call is not equivalent to a process termination
after the filesystem accepted the write.

## Transaction and deadlock diagnosis

Capture transaction lifecycle events: begin, snapshot, lock wait, lock grant,
savepoint, statement error, rollback, commit request, durable commit, and
connection close. For a deadlock, draw a wait-for graph from transaction IDs
and locks. Verify the selected victim’s before-images were applied and that
all locks and snapshots were released.

For a timeout or cancellation, answer three questions:

1. Did the server stop executing the request?
2. Did the transaction commit, roll back, or remain unknown?
3. Were connection, lock, snapshot, and temporary resources released?

Do not retry a write with an unknown outcome unless it is idempotent or the
application can query the request/transaction outcome.

## WAL and recovery diagnosis

Preserve the complete database directory, WAL, metadata, and service logs.
Record file sizes, modification times, checksums, checkpoint LSN, last
acknowledged LSN, and the process termination reason. Run inspection and
restore against a copy. Compare:

```text
checkpoint LSN <= durable WAL end LSN
last acknowledged commit <= durable WAL end LSN
restored checksum == manifest checksum
replayed transaction set == committed transaction set
```

For corruption, stop writes and escalate rather than repeatedly reopening the
original. For a compaction issue, compare row counts, indexes, checksums, and
reopen behavior before and after compaction on a copy.

## Wire and protocol debugging

Use a local test endpoint and sanitized packet/frame logging. Validate one
request at a time: handshake, authentication, capability negotiation, query,
result frames, cancellation, and close. Check frame length, request ID,
sequence, status, and error payload. Test partial reads and writes because a
single `read` or `write` is not guaranteed to transfer a complete frame.

For an in-flight cancellation race, log the request ID and server state at
cancel receipt, executor stop, transaction decision, and response emission.
The client must distinguish cancellation accepted, cancellation too late, and
unknown connection loss.

## Rails debugging

Enable Rails SQL logging in a non-production reproduction and redact bind
values before sharing. Compare the generated SQL with a direct RubyDB query.
For adapter bugs, create the smallest model and migration that shows the
problem, then test both a fresh schema and a populated table. Inspect:

* quoting and bind parameter order;
* transaction/savepoint boundaries;
* affected rows and last-insert ID;
* schema introspection and default values;
* pool checkout/checkin and leaked transactions; and
* exception class and retry behavior.

Use the Rails example under `examples/rails_app` as a smoke harness before
reproducing inside a large application.

## Ruby-level tools

For a focused local reproduction, Ruby’s standard tools are usually enough:

```sh
RUBYOPT="-d" bundle exec rspec spec/path/to/failing_spec.rb
bundle exec ruby -w -Ilib path/to/reproduction.rb
```

`TracePoint` can observe method calls and exceptions without modifying the
engine. Use it only in a short-lived reproduction because tracing changes
timing and can invalidate concurrency conclusions. Capture thread backtraces
when a process appears hung, and include the thread roles (acceptor, worker,
checkpoint, replication, application).

## Performance debugging

Separate CPU, lock, I/O, and queue time. Record p50/p95/p99 latency, throughput,
errors, WAL growth, checkpoint duration, memory, file descriptors, and active
transactions. Change one variable per run and repeat enough times to expose
variance. A faster benchmark with weaker durability is not an equivalent
optimization.

Use:

```sh
RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb
ruby benchmarks/concurrent_workload.rb
ruby scripts/production_soak
```

Keep benchmark artifacts out of commits unless they are intentional fixtures.

## Fuzzing and property failures

Save the seed, generated SQL/input, Ruby version, commit, and failing database
directory. Reduce the number of operations while preserving the seed. Check
the invariant: no crash, no invalid state, rollback equivalence, parser
round-trip, or index/table agreement. Add the minimized case as a deterministic
spec, then keep the fuzz run as a secondary guard.

## What not to do

Do not delete WAL or lock files, edit database bytes manually, disable checksum
validation, run repair on the only copy, force a replica promotion without
fencing, or publish sanitized logs that still contain secrets. These actions
can turn a diagnosable incident into irreversible data loss or a security
incident.

## Diagnostic report template

```text
Summary:
First observed (UTC):
RubyDB version/commit:
Ruby/Rails/OS/filesystem:
Topology and ownership mode:
Configuration names/checksum:
Command or request shape:
Request/transaction/LSN IDs:
Expected result:
Actual result:
Reproduction and seed:
Logs/metrics/checksums:
Actions already taken:
Data impact and current containment:
```

