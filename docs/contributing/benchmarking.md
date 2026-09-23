# Benchmarking guide

Run deterministic and concurrent workloads from the repository root:

```sh
RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb
RUBYDB_SOAK_THREADS=16 RUBYDB_SOAK_OPERATIONS=2000 ruby benchmarks/concurrent_soak.rb
RUBYDB_PRODUCTION_SOAK_CLIENTS=16 RUBYDB_PRODUCTION_SOAK_OPERATIONS=2000 ruby benchmarks/production_soak.rb
# Ruby-vs-Go read pipeline benchmark (10,000 rows minimum)
RUBYDB_ACCELERATOR_ROWS=10000 RUBYDB_ACCELERATOR_ITERATIONS=5 \
RUBYDB_ACCELERATOR_THREADS=4 RUBYDB_ACCELERATOR_REQUESTS=5 \
bundle exec ruby benchmarks/go_accelerator.rb
```

Record commit, Ruby version, OS, CPU/memory/storage, dataset size, seed,
throughput, p50/p95/p99 latency, WAL growth, and recovery time. Benchmarks are
not universal capacity certification; compare against application-specific
limits and repeat after schema or runtime changes.

For Ruby hot-path changes, also record allocated objects, total allocated
bytes, GC count, GC time, and peak RSS. Compare the same query with the same
catalog, indexes, cache state, and transaction boundaries. Do not call
`GC.start` inside the measured request; that hides the allocation problem and
does not represent normal application behavior.

The accelerator benchmark reports separate Ruby and Go timings, correctness,
CPU/RSS snapshots, concurrency errors, and worker lifecycle counters. It
restarts the worker and verifies that concurrent requests return the same rows.
A Go result is only useful if it is compared with the same rows, predicates,
ordering, and result count. The Go leg uses `mode: required`; the Ruby leg is
deliberately labeled `off` and does not invoke the worker. Set
`RUBYDB_ACCELERATOR_REQUIRE_SPEED=1` in CI only when the representative
workload has a known speed win. The runtime's `auto` policy performs an
equivalent comparison per workload family before keeping an operator enabled.
Keep the JSON output with the commit and hardware record; never use a single
laptop run as a production capacity guarantee.

Use the long-lived worker for application-query comparisons. A one-shot Go
process is appropriate for maintenance exports but includes startup and
checksum overhead, so it must not be used to claim that Go is faster for
small Rails requests. A Go optimization is accepted only when it has a Ruby
dispatch path, differential correctness coverage, bounded resource usage, and
a repeatable steady-state win for a named workload.

The accelerator source is audited the same way. Unimported or unreachable Go
helpers are removed rather than shipped as speculative performance work.
