# RubyDB production operations guide

This guide describes a controlled production deployment for applications that
fit RubyDB’s documented feature surface. It is an operational companion to
the [production runbook](production-runbook.md), [disaster recovery guide](disaster-recovery.md),
and [monitoring guide](monitoring.md). It does not turn the current project
into a universal PostgreSQL, MySQL, or SQLite replacement.

## Deployment decision

Choose embedded mode only when one process owns the database directory and the
application accepts process-local availability. Use server mode when web,
worker, migration, or administrative processes need concurrent access. Put
the database directory on storage with documented durability and rename/
flush semantics. Do not place it on an untested shared filesystem.

Before launch, validate the application’s schema, generated SQL, migrations,
backup/restore path, concurrency profile, and failure behavior against the
exact RubyDB version and configuration that will be deployed.

## Reference topology

```text
clients/web/workers -> TLS -> RubyDB server -> private database volume
                                      |-> WAL/checkpoints
                                      |-> verified backup destination
                                      |-> metrics/log sink
optional replica --------------------^
```

A replica is not a backup. A backup is not a fencing system. An application
load balancer health check is not proof that a primary is safe to write. Keep
these responsibilities separate.

## Configuration and service identity

Run the server as a dedicated least-privilege account. Give it access only to
the database, WAL, temporary, certificate, and backup paths it needs. Store
passwords, peer tokens, private keys, and API credentials in a secret manager.
Do not put secrets in YAML committed to the repository, process arguments, or
logs.

Pin the RubyDB version and configuration for each deployment. Review changes to
durability mode, WAL retention, checkpoint thresholds, memory, connection
limits, request deadlines, lock timeouts, and TLS/authentication as production
changes. Keep a configuration checksum in the deployment record.

## Readiness checklist

Before accepting traffic:

* database directory is on approved storage with sufficient space and inodes;
* service account and file permissions are verified;
* TLS certificate, key, CA, hostname, and expiration are checked;
* authentication and authorization deny an unauthenticated test client;
* health and readiness checks exercise a real request path;
* connection, request, lock, and shutdown timeouts are bounded;
* schema/migrations have completed and version/checksum is recorded;
* full backup has been created and restored into a fresh directory;
* monitoring, alert routing, and log retention are active;
* rollback and restore owners are named; and
* a representative smoke query and write have passed.

## Capacity and resource limits

Set explicit limits for connections, request duration, lock waits, result size,
memory, worker count, WAL size, backup space, and file descriptors. Size the
application pool below the server limit, leaving room for migrations,
replication, health checks, and administration. A pool that equals the server
limit can starve the control plane.

Alert before exhaustion, not after it. Watch CPU, RSS, open files, disk bytes,
free inodes, WAL bytes, checkpoint age/duration, active transactions, lock
waits, pool utilization, errors, cancellations, and p95/p99 latency.

## Backup policy

Define RPO and RTO with the application owner. At minimum, maintain verified
full backups, protect them from the database host, encrypt them at rest and in
transit, retain multiple generations, and record manifests/checksums. If using
incremental or differential backups, retain their verified base and ordered
chain.

A successful backup command is not proof of recoverability. Regularly restore
to an isolated directory, validate checksums and schema, run representative
queries, compare critical row counts, and record elapsed restore time. Run a
restore drill after format, backup, storage, or release changes.

## Upgrade procedure

1. Read the release notes, format compatibility, and migration notes.
2. Create and verify a new full backup.
3. Test the new version against a restored production-like copy.
4. Run schema and application smoke tests, including populated-table writes.
5. Drain or fence writes according to the deployment topology.
6. Upgrade one controlled instance and verify health, WAL, and metrics.
7. Re-enable traffic gradually and watch errors and latency.
8. Keep the rollback binary and backup available until the validation window
   closes.

Never roll back by pointing an older binary at a directory whose format or
metadata it cannot read. Use the documented restore/rollback path.

## Failover procedure

RubyDB’s safe failover model requires a synchronized candidate and a durable
fencing decision. A manual operator sequence is:

1. declare the incident and stop or isolate application writes;
2. verify the primary’s last acknowledged LSN and fence epoch;
3. confirm the candidate’s applied LSN and integrity;
4. fence the old primary at the process, host, storage, or network layer;
5. promote only after fencing is observable and durable;
6. point clients at the new primary and run smoke writes/reads;
7. monitor replication and stale-writer rejection; and
8. recover the old primary as a replica only after its state is understood.

Automatic election requires an independently validated quorum, fencing,
partition behavior, stale-primary rejection, and recovery procedure. Do not
enable election based solely on a successful same-host test.

## Incident response

Contain first: stop unsafe writes, protect the database directory, and record
the timeline. Preserve logs, metrics, WAL, metadata, configuration, process
state, and backup manifests. Use [troubleshooting](../troubleshooting.md) and
[debugging](../debugging.md) for evidence collection.

Classify the event as availability, durability, correctness, security, or
capacity. Assign an incident owner and a recovery owner. Communicate whether
commit outcomes are known, unknown, or confirmed rolled back. After recovery,
verify application invariants rather than relying only on process health.

## TLS and secret rotation

Stage new certificates and CA material, validate the chain and hostname with a
test client, then switch through an atomic deployment/configuration change.
Maintain an overlap window only if clients support it. Confirm old material is
no longer accepted before revoking it. Rotate database passwords and peer
tokens through the secret manager; audit access and avoid printing values.

## Maintenance

Schedule vacuum, compaction, checkpoint, index maintenance, and backups with
awareness of active readers and write load. Measure before and after. Use a
copy for repair or compaction experiments. Verify reopen, checksums, row counts,
indexes, and application smoke queries after maintenance.

## Production evidence

The release record should contain the RubyDB commit, Ruby/Rails versions,
configuration checksum, schema/migration version, backup manifest, restore
drill result, benchmark/soak result, monitoring link, security review status,
and known limitations. See [production readiness](../production-readiness.md)
for the project-level boundaries.

