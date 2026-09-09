# RubyDB roadmap

## Current phase: validated foundation

RubyDB has a durable storage/WAL/recovery foundation, transactions and MVCC,
the documented SQL engine, server/client protocol, Rails adapter coverage,
backups, logical replication, monitoring, fuzzing, and release automation.
The latest local audit passed 270 examples with zero failures.

## Next gates

1. Retain hosted Ruby/Rails/OS matrix evidence for each release.
2. Run physical filesystem quota, power-loss, corruption, restore, and compaction
   drills on deployment targets.
3. Validate multi-host replication partitions, independent fencing, stale
   primary rejection, and operator promotion procedures.
4. Complete certificate/secret rotation validation and an independent security
   review.
5. Establish workload-specific latency, throughput, capacity, RPO, and RTO
   baselines.

## Longer term

Expand the documented SQLite-style profile and only then consider broader
PostgreSQL/MySQL compatibility where implementation and semantic validation can
be maintained. Add automatic election only with an independently tested fencing
authority. Preserve correctness and explicit unsupported errors as hard gates.
