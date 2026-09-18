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
