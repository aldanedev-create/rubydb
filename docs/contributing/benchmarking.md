# Benchmarking guide

Run deterministic and concurrent workloads from the repository root:

```sh
RUBYDB_BENCHMARK_ITERATIONS=100 ruby -Ilib benchmarks/basic_workload.rb
RUBYDB_SOAK_THREADS=16 RUBYDB_SOAK_OPERATIONS=2000 ruby benchmarks/concurrent_soak.rb
RUBYDB_PRODUCTION_SOAK_CLIENTS=16 RUBYDB_PRODUCTION_SOAK_OPERATIONS=2000 ruby benchmarks/production_soak.rb
```

Record commit, Ruby version, OS, CPU/memory/storage, dataset size, seed,
throughput, p50/p95/p99 latency, WAL growth, and recovery time. Benchmarks are
not universal capacity certification; compare against application-specific
limits and repeat after schema or runtime changes.
