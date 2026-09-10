# Lesson 9: observability, security, and scale

Production readiness is an operating discipline. A database is ready only when
the team can see failures, limit damage, rotate credentials, and make a safe
recovery decision under pressure.

## Protect the connection

For RubyDB server mode, use a private network, password authentication, and
TLS with peer verification:

```text
rubydbs://app_user:URL_ENCODED_PASSWORD@db.internal.example:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Fca.crt
```

Store `RUBYDB_URL`, `RUBYDB_PASSWORD`, certificates, and private keys in the
deployment secret manager. Do not commit them, put them in a Docker image, or
print them in health checks. Give the application only the database privileges
it needs and use a separate migration/admin identity.

For PostgreSQL, use `DATABASE_URL` from the provider’s secret store, TLS
settings required by that provider, least-privilege roles, and rotated
credentials. Review role grants after every schema or service change.

## Set limits before load

Bound every layer that can wait:

```yaml
# config/database.yml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
  checkout_timeout: <%= ENV.fetch("DB_CHECKOUT_TIMEOUT", "5") %>
```

Also set application request/job timeouts, connection idle limits, server
connection limits, maximum request body sizes, and process memory/CPU limits.
Choose values from measurements. A timeout should fail a request cleanly and
produce a useful event; it should not cause an unsafe blind retry.

## Monitor signals that lead to incidents

Collect metrics and structured logs for:

* request and query latency by operation, including p95 and p99;
* error, timeout, cancellation, retry, and deadlock counts;
* active connections, pool wait time, and transaction age;
* WAL/checkpoint growth, database size, free disk, and compaction/vacuum time;
* backup age, backup verification result, restore drill age, and RPO/RTO; and
* process restarts, readiness failures, replication lag, and failover events.

The RubyDB CLI is useful evidence in an operator check:

```sh
rubydb --env production status --json
rubydb --env production doctor --quick --json
rubydb inspect --database data/app.rdb --stats --wal
```

Turn those outputs into alerts with thresholds and an owner. A green process
status is not the same as a healthy application: include a real application
query and a write/read smoke test in staging and deployment verification.

## Load and concurrency validation

Start with a reproducible workload, then increase concurrency gradually:

```sh
RUBYDB_WORKLOAD_THREADS=16 RUBYDB_WORKLOAD_OPERATIONS=10000 \
  ruby benchmarks/concurrent_workload.rb
```

Use the repository’s documented workload script and record its output. Measure
throughput, latency, failures, cancellations, timeouts, deadlocks, memory, WAL,
and disk use. Run long enough to expose leaks and queue growth. Test separate
processes and separate hosts for server mode; an in-process benchmark does not
prove network behavior.

## Checkpoint

The checkpoint passes when alerts have thresholds and owners, secrets can be
rotated without source changes, resource limits are documented, and a sustained
test produces a baseline with no unexplained errors or unbounded growth.
Continue to [lesson 10](10-release-readiness.md) for the release gate.
