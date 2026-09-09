# Remaining production work

Completed checkpoints: exclusive embedded engine ownership, duplicate-open
rejection, release after process exit, initialization failure cleanup, fail-closed
metadata and recovery startup, atomic metadata replacement, and deterministic
background-maintenance shutdown.

The following work remains open; passing the regression suite does not certify
these capabilities.

1. Server concurrency: isolation checks, deadlines, cancellation, and sustained
   load with latency percentiles. A real multi-process client workload now
   verifies process isolation and durable contents through the server; mixed
   transaction reference-log and restart validation remain open.
2. Persistence: fault-test disk-full and interrupted checkpoints/schema changes;
   index metadata load and write errors now fail visibly, and failed schema
   publications roll back in-memory state. Add a durable write-ack protocol so
   callers can distinguish a committed mutation from an uncertain I/O failure.
3. SQL correctness: ambiguous identifiers, outer-join NULL handling, boolean
   preservation, aggregate edge cases (NULLs, DISTINCT, and expressions), and
   schema changes on populated tables. Non-recursive CTEs, subqueries, set
   operations, targeted `ON CONFLICT DO UPDATE`, and ranking/partition window
   functions are implemented; recursive CTEs, window frames, and broader upsert
   forms remain open.
4. Replication: synchronized acknowledgements and promotion with an explicit
   recovery point. Engine commits now package all committed row changes into a
   single replication envelope after the local WAL commit point. Primary
   connections bootstrap the catalog before row replay, including empty replicas. TCP input now
   uses bounded newline framing and replay positions are fsynced before ack;
   replica engine mutation entry points are read-only except for internal replay.
   Validate partitions and stale writers before adding automatic election.
5. Rails: populated migration round trips, schema dump/load, eager loading,
   nested associations, connection pools and a supported-version CI matrix.
6. Operations: complete backup manifests, automated restore drills, upgrade
   tests, measured resource limits, alerting, and security review of replication
   endpoints and authorization enforcement.

Deployment tests must record the commit, platform, workload and measured
results. Keep untested features marked as unvalidated.
