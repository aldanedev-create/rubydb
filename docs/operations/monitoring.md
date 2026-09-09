# Monitoring and alerting

Expose the RubyDB health and Prometheus endpoints through the deployment’s
authenticated monitoring path. Use liveness to decide whether a process
exists; use readiness to decide whether it is safe to route traffic.

At minimum, collect:

- request count, error count, latency, and active connections;
- WAL bytes/segments, checkpoint failures, flush failures, and recovery-required
  commit acknowledgements;
- table/index counts, row counts, storage bytes, and vacuum/compaction duration;
- replication role, state, received/replayed LSN, lag, authentication failures,
  and fencing epoch;
- process memory, CPU, open files, and filesystem free space.

Alert on readiness failure, repeated request errors, checkpoint or WAL flush
failures, any recovery-required acknowledgement, filesystem space below the
service threshold, replication lag beyond the application RPO, authentication
failures, and a fencing epoch change.

Dashboards must show rates and percentiles over time, not only current gauges.
Set thresholds from staging workload measurements and review them after every
capacity or schema change. A green liveness check alone is not evidence that
the database can accept traffic.
