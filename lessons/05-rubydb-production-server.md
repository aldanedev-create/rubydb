# Lesson 5: RubyDB server production setup

Server mode puts one RubyDB process in charge of the data directory and lets
Ruby or Rails clients connect over the RubyDB protocol. This is the correct
RubyDB topology when several application processes need one database. The
application must never open the server’s `.rdb` files directly.

## Provision the service

Use a dedicated service account and persistent storage. The commands below
assume a Unix-like host; adapt ownership commands to your platform:

```sh
gem install rubydb -v 0.1.5
install -d -o rubydb -g rubydb -m 0700 /var/lib/rubydb/data
install -d -o rubydb -g rubydb -m 0750 /var/log/rubydb
install -d -o rubydb -g rubydb -m 0700 /etc/rubydb
```

Keep `/var/lib/rubydb` on persistent storage and place backups in a separate
failure domain. Restrict the database port to the application network.

## Configuration and startup

Create `/etc/rubydb/production.yml` from the repository’s production template.
Supply credentials and TLS paths through a secret manager or protected
deployment environment. A production configuration needs WAL, durable storage,
authentication, TLS, and bounded resources.

Start the supervised foreground process:

```sh
rubydb --config /etc/rubydb/production.yml --env production start
```

For a development smoke server, the CLI also accepts explicit settings:

```sh
rubydb --env production start \
  --host 127.0.0.1 \
  --port 7432 \
  --data-dir /var/lib/rubydb/data \
  --log-dir /var/log/rubydb \
  --pid-file /run/rubydb.pid
```

Use systemd, a container supervisor, or the platform’s process manager to
restart the process and preserve logs. Do not let an orchestrator launch two
writers against one embedded path.

## Straight-to-production deployment path

Use this path when RubyDB is the chosen production database for a bounded
service. It works for a Rails app or a regular Ruby app. For a massive shared
application, use the PostgreSQL path in [lesson 6](06-postgresql-massive-apps.md)
instead.

### 1. Prepare the database host

The database host needs a persistent local volume, a dedicated service account,
and a private network route from the application. Run these commands as an
administrator and replace paths only after verifying the target host:

```sh
gem install rubydb -v 0.1.5
useradd --system --home-dir /var/lib/rubydb --shell /usr/sbin/nologin rubydb
install -d -o rubydb -g rubydb -m 0700 /var/lib/rubydb/data
install -d -o rubydb -g rubydb -m 0750 /var/log/rubydb
install -d -o root -g rubydb -m 0750 /etc/rubydb
```

Copy the reviewed `config/production.yml` from the RubyDB repository to
`/etc/rubydb/production.yml`. Keep the database directory and WAL on approved
persistent storage. Keep backups on another host or failure domain.

### 2. Install secrets and TLS material

Use a CA-issued certificate for a real deployment. Do not use a self-signed
development certificate for public traffic. Inject these values through a
secret manager, protected service environment, or equivalent mechanism:

```text
RUBYDB_USERNAME=app_rw
RUBYDB_PASSWORD=generated-secret
RUBYDB_SSL_ENABLED=true
RUBYDB_SSL_CERT_FILE=/etc/rubydb/tls/server.crt
RUBYDB_SSL_KEY_FILE=/etc/rubydb/tls/server.key
RUBYDB_SSL_CA_FILE=/etc/rubydb/tls/ca.crt
RUBYDB_SSL_VERIFY_PEER=true
```

Restrict the private key and environment file to the service. Do not put
secrets in Git, Docker images, process arguments, shell history, or logs.
Allow port `7432` only from the application and administration networks.

### 3. Start and verify RubyDB

Start the foreground process under a service manager such as systemd:

```sh
sudo -u rubydb env RUBYDB_USERNAME=app_rw RUBYDB_PASSWORD='from-secret-store' \
  rubydb --config /etc/rubydb/production.yml --env production start
```

Verify the server from the application network:

```sh
rubydb --config /etc/rubydb/production.yml --env production status --json
rubydb --config /etc/rubydb/production.yml --env production doctor --json
```

Run an authenticated TLS query using the same URL that the app will use. The
password below is intentionally a secret-manager value, not a real credential:

```sh
RUBYDB_URL='rubydbs://app_rw:URL_ENCODED_PASSWORD@db.internal:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt' \
  ruby -rrubydb -e 'c=RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL")); p c.query("SELECT 1").to_hash; c.disconnect'
```

### 4. Deploy Rails or Ruby

For Rails, use server mode and inject the URL:

```yaml
# config/database.yml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

For a regular Ruby service:

```ruby
require "rubydb"

client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
begin
  result = client.query("SELECT 1")
  puts result.to_hash
ensure
  client.disconnect
end
```

Deploy the application artifact with the pinned RubyDB gems, then run schema
migrations once from a controlled release job:

```sh
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails db:migrate:status
RAILS_ENV=production bundle exec rails runner 'puts ApplicationRecord.connection.select_value("SELECT 1")'
```

The web and worker processes connect to `RUBYDB_URL`; they never mount or open
the server’s database directory.

### 5. Back up before accepting traffic

Create and verify a full backup, then perform a restore into an inactive path:

```sh
rubydb backup --database /var/lib/rubydb/data/app.rdb \
  --dir /var/backups/rubydb --type full --compress
rubydb restore --database /var/lib/rubydb/restore-check.rdb \
  --dir /var/backups/rubydb --latest --dry-run
rubydb restore --database /var/lib/rubydb/restore-check.rdb \
  --dir /var/backups/rubydb --latest --force
```

Complete an actual isolated restore and run representative reads before the
first public request. Record the backup checksum, restore duration, RPO, RTO,
and the operator responsible.

### 6. Release traffic gradually

Start with a canary or a small percentage of traffic. Verify one read, one
write transaction, one background job, and one application error path. Watch
latency, errors, active connections, WAL/checkpoint growth, memory, and free
disk. Keep the previous app artifact and verified backup until the rollback
window closes.

This path makes RubyDB usable in production for a validated bounded workload;
it does not provide automatic multi-host high availability by itself. If the
service needs automatic election, cross-host failover, or PostgreSQL-specific
SQL, stop and complete the corresponding validation or choose PostgreSQL.

## Rails connection

```yaml
# config/database.yml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

Use TLS verification in the URL:

```text
rubydbs://app_user:URL_ENCODED_PASSWORD@db.internal.example:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Fca.crt
```

Inject `RUBYDB_URL` from a secret manager. Percent-encode special characters
in credentials, and never print the complete URL. The server must separately
define its authentication credentials, certificate, private key, and CA.

## Smoke test before traffic

```sh
rubydb --config /etc/rubydb/production.yml --env production status --json
rubydb --config /etc/rubydb/production.yml --env production doctor --quick --json
RAILS_ENV=production bundle exec rails db:migrate:status
RAILS_ENV=production bundle exec rails runner 'puts ApplicationRecord.connection.select_value("SELECT 1")'
```

Then exercise one authenticated read, one transaction that creates and updates
data, one background job, and one verified backup/restore drill. Capture the
RubyDB version, application release, configuration checksum, and test output.

## Cloud deployment shape

On a platform such as Render, use a private database service with a persistent
disk and a separate web service. Put the private hostname in `RUBYDB_URL` and
keep both services in the same region. A web-service scale-out is not database
high availability; maintain external backups and validate a failover design
before relying on it.

## Checkpoint

The checkpoint passes when multiple app processes connect over TLS, writes are
visible to another client, migrations run once from a release job, readiness
checks are monitored, and a restore has been tested into a new directory.
Continue to [lesson 6](06-postgresql-massive-apps.md) to decide when PostgreSQL
is the better production choice.
