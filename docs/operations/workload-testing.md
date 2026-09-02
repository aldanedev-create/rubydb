# Workload testing

Run the deterministic concurrent workload from the repository root:

```sh
RUBYDB_WORKLOAD_THREADS=4 RUBYDB_WORKLOAD_OPERATIONS=250 ruby benchmarks/concurrent_workload.rb
```

It performs concurrent inserts against one engine, verifies the final row count, closes the database, reopens it, and verifies durable reads. It prints one JSON result and exits non-zero on any operation or durability failure.

Use a temporary database by default. To retain an artifact for inspection, provide an explicit path:

```sh
RUBYDB_WORKLOAD_PATH=/var/lib/rubydb/workload.rdb RUBYDB_WORKLOAD_THREADS=16 RUBYDB_WORKLOAD_OPERATIONS=10000 ruby benchmarks/concurrent_workload.rb
```

Run this in a staging environment on the target filesystem before deployment. Establish acceptable latency, throughput, WAL growth, disk-space, recovery-time, and backup/restore targets for the expected workload; do not treat a successful smoke workload as capacity certification.
