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

## Complete first deployment

The following is a reference deployment for a Rails or regular Ruby
application. Replace paths, hostnames, users, and limits with values approved
by your infrastructure team.

### 1. Install and provision the server

Pin the RubyDB gem version on the database host. Do not use an unpinned
prerelease in a production deployment:

```sh
gem install rubydb -v 0.1.0
useradd --system --home-dir /var/lib/rubydb --shell /usr/sbin/nologin rubydb
install -d -o rubydb -g rubydb -m 0700 /var/lib/rubydb/data
install -d -o rubydb -g rubydb -m 0750 /var/log/rubydb
install -d -o root -g rubydb -m 0750 /etc/rubydb
```

Use a persistent local volume for `/var/lib/rubydb/data`. Keep backups on a
separate failure domain. The server account should not own application source,
certificate private keys, or unrelated host data.

### 2. Configure the server

Start from the repository’s `config/production.yml` and place a reviewed copy
at `/etc/rubydb/production.yml`. Supply required secrets through the service
manager or secret store. At minimum, configure:

```text
RUBYDB_HOST=0.0.0.0
RUBYDB_PORT=7432
RUBYDB_DATA_DIR=/var/lib/rubydb/data
RUBYDB_LOG_DIR=/var/log/rubydb
RUBYDB_USERNAME=app_rw
RUBYDB_PASSWORD=<secret-manager-value>
RUBYDB_SSL_ENABLED=true
RUBYDB_SSL_CERT_FILE=/etc/rubydb/tls/server.crt
RUBYDB_SSL_KEY_FILE=/etc/rubydb/tls/server.key
RUBYDB_SSL_CA_FILE=/etc/rubydb/tls/ca.crt
RUBYDB_SSL_VERIFY_PEER=true
```

The server’s TLS private key and application password must be readable only by
the service or secret-management mechanism. Restrict port `7432` to the Rails
and worker network; do not expose it to the public internet.

### 3. Start and verify the server

Run it under systemd, a supervised container, or an equivalent process
manager. The CLI configuration options must appear before the command:

```sh
sudo -u rubydb env RUBYDB_USERNAME=app_rw RUBYDB_PASSWORD='from-secret-store' \
  rubydb --config /etc/rubydb/production.yml --env production start
```

In a systemd unit, use an `EnvironmentFile` protected with mode `0600` or a
native secret integration, then use:

```ini
ExecStart=/usr/local/bin/rubydb --config /etc/rubydb/production.yml --env production start
Restart=on-failure
```

Verify from the application network, not only from the database host:

```sh
rubydb --config /etc/rubydb/production.yml --env production status --json
rubydb --config /etc/rubydb/production.yml --env production doctor --json
```

Then run an authenticated TLS smoke query using the Ruby client and the same
URL the application will use:

```sh
RUBYDB_URL='rubydbs://app_rw:URL_ENCODED_PASSWORD@db.example.com:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt' \
  ruby -rrubydb -e 'c=RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL")); p c.query("SELECT 1").to_hash; c.disconnect'
```

### 4. Configure a Rails application

In the Rails application’s `config/database.yml`, select server mode and read
the connection string from the deployment environment:

```yaml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

Set `RUBYDB_URL` through the platform secret store:

```text
RUBYDB_URL=rubydbs://app_rw:URL_ENCODED_PASSWORD@db.example.com:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

Deploy the Rails application, then run the migration once using a controlled
release job, not concurrently from every web process:

```sh
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails runner 'puts User.count'
```

The web and job processes connect to the server endpoint. They never mount or
open `/var/lib/rubydb/data`.

### 5. Configure a regular Ruby application

The regular client uses the same environment value:

```ruby
require "rubydb"

client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
begin
  client.query("SELECT 1")
  client.query("INSERT INTO audit_events (event_name) VALUES (?)", ["boot"])
ensure
  client.disconnect
end
```

Use application-level idempotency for retried writes. A network timeout does
not by itself prove that a commit was rolled back.

### 6. Accept traffic gradually

Run a read/write smoke test, migration status check, backup, and representative
workload before routing all traffic. Watch p95/p99 latency, errors, lock waits,
active connections, WAL growth, checkpoint age, disk space, and memory during a
canary period. Keep the previous application version and verified database
backup available until the rollback window closes.

The Rails URL example and URL option reference are also maintained in [Rails
database configuration](../rails/database-yml.md).

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
