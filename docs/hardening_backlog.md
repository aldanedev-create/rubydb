# Remaining production work

Completed checkpoints: exclusive embedded engine ownership, duplicate-open
rejection, release after process exit, initialization failure cleanup, fail-closed
metadata and recovery startup, atomic metadata replacement, and deterministic
background-maintenance shutdown.

The following work remains open; passing the regression suite does not certify
these capabilities.

1. Server concurrency: multiple client processes performing mixed transactions,
   isolation checks, deadlines, cancellation, and sustained load with latency
   percentiles. Verify committed contents after restart against a reference log.
2. Persistence: propagate index write errors; fault-test disk-full, interrupted
   checkpoints and schema changes; add a durable write-ack protocol so callers
   cannot observe a failed metadata publication as a committed schema change.
3. SQL correctness: ambiguous identifiers, outer-join NULL handling, boolean
   preservation, aggregate edge cases (NULLs, DISTINCT, and expressions), and
   schema changes on populated tables. Follow with subqueries, CTEs, set
   operations, window functions and upserts.
4. Replication: TCP frame buffering, durable replay positions, synchronized
   acknowledgements, bootstrap, transaction/WAL integration, read-only replicas,
   and promotion with an explicit recovery point. Validate partitions and stale
   writers before adding automatic election.
5. Rails: populated migration round trips, schema dump/load, eager loading,
   nested associations, connection pools and a supported-version CI matrix.
6. Operations: complete backup manifests, automated restore drills, upgrade
   tests, measured resource limits, alerting, and security review of replication
   endpoints and authorization enforcement.

Deployment tests must record the commit, platform, workload and measured
results. Keep untested features marked as unvalidated.
