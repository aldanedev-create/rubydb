# RubyDB production runbook

## Before deployment

1. Pin the RubyDB commit and Ruby version. Run `bundle exec rspec`, the
   production soak, the durability drill, and the network failover drill.
2. Place the database, WAL, lock file, replication state, and backups on
   protected storage owned by the service account. Keep backups on a separate
   failure domain.
3. Enable TLS, use a private bind address, configure authentication and a
   replication token from a secret manager, and set connection, frame, query,
   worker, and disk-space limits.
4. Install the alert rules in
   `config/monitoring/prometheus-alerts.yml`. Test readiness, metrics, backup,
   and restore from the deployment environment.

## Backup and restore

Run a full backup before upgrades and retain the matching WAL chain and
manifest. Restore into a new inactive directory, run the restore drill, reopen
the database, compare row counts/checksums, and only then switch traffic.
Never overwrite the only copy during a restore.

## Failover

Stop writes, confirm the replica is synchronized, fence the old primary using
the shared durable fence path, promote exactly one replica, and verify client
writes and replication status. Automatic election is not enabled until the
deployment provides an independently tested fencing lease. A network partition
must never result in two writable primaries.

## TLS and secret rotation

Stage a new certificate/key and replication token in the secret manager,
validate them on an inactive instance, restart or drain one peer at a time,
verify TLS and replication authentication, then revoke the old credentials
after the overlap window. Do not place secrets in repository files, command
arguments, URLs, or logs.

## Upgrade and incident response

Run the upgrade-compatibility suite against a copy of production backups.
Preserve the database, WAL, replication state, logs, metrics, and timestamps
before repair, vacuum, restore, or promotion. If checksums, fencing, or
replication diverge, stop writes and escalate; do not guess at a repair.
