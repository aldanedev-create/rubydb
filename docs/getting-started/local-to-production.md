# From local development to production

This guide is for a beginner starting with a Ruby or Rails application. It
shows two valid deployment choices:

1. develop with RubyDB locally and deploy with PostgreSQL; or
2. develop with RubyDB locally and keep RubyDB in production.

The application code can be similar in both cases, but the database is not
interchangeable by copying files. Choose the production database before
launch, run the application’s migrations and query tests against it, and make
backups before importing important data.

## Which path should I choose?

| Goal | Local database | Production database | Recommended when |
| --- | --- | --- | --- |
| Learn/build quickly | RubyDB embedded | PostgreSQL | You want the broadest hosting and Rails ecosystem |
| Keep one Ruby-native database | RubyDB embedded | RubyDB server | Your SQL/workload fits RubyDB and you can operate the server |
| Prototype only | RubyDB embedded | RubyDB embedded | One process owns the path and data is non-critical |

For a public or business-critical application, PostgreSQL is the safer default
until RubyDB has been validated against your complete workload, backup/restore
process, concurrency, and failover requirements. RubyDB is not a complete
PostgreSQL or SQLite replacement.

## Part 1: local Rails development with RubyDB

### 1. Add the gems

In the Rails application `Gemfile`:

```ruby
gem "rubydb"
gem "rubydb-activerecord"
gem "pg" # Keep this if PostgreSQL is a possible production target.
```

Run:

```sh
bundle install
```

### 2. Configure development and test

Use an embedded path for local development. Only the Rails process should own
each path:

```yaml
default: &default
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/rubydb_development.rdb") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>

development:
  <<: *default

test:
  <<: *default
  database: <%= Rails.root.join("tmp/rubydb_test.rdb") %>
```

Use separate development and test paths. Do not put the database under a
source-controlled directory. Do not let a web server, job worker, and console
open the same embedded path at the same time.

### 3. Create the schema and run the app

```sh
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed       # only if your seed data is safe to recreate
bin/rails test
bin/rails server
```

Exercise real application flows: sign-up, login, CRUD, joins, eager loading,
background jobs, file metadata, transactions, and error handling. Do not test
only that the server boots.

### 4. Use RubyDB in a regular Ruby app

Local single-process code can use the embedded engine:

```ruby
require "rubydb"

engine = RubyDB::Storage::Engine.new("tmp/app.rdb")
begin
  engine.execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, name TEXT)")
  engine.execute("INSERT INTO events (name) VALUES (?)", ["boot"])
  p engine.execute("SELECT * FROM events")
ensure
  engine.close
end
```

For multiple processes, use the client/server connection described below.

## Part 2A: deploy the same app on PostgreSQL

This path keeps RubyDB for local development and uses PostgreSQL in production.
It is a database migration, not a file copy.

### 1. Configure the production Rails block

```yaml
production:
  adapter: postgresql
  url: <%= ENV.fetch("DATABASE_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

The hosting provider supplies a PostgreSQL URL such as:

```text
postgresql://app_user:password@postgres.example.com:5432/my_app
```

Keep `DATABASE_URL` in the provider’s secret settings. Never commit it.

### 2. Review the schema and SQL

Before switching, review RubyDB-specific behavior:

* integer primary-key/autoincrement behavior;
* `BOOLEAN`, `JSON`, `UUID`, dates, timestamps, and decimals;
* indexes, foreign keys, check constraints, and defaults;
* `NULL`, ordering, grouping, joins, upserts, and functions;
* migrations that alter populated tables; and
* raw SQL, extensions, pragmas, and database-specific functions.

Run `db:schema:dump` and inspect the generated schema. Do not assume every
RubyDB schema statement is valid PostgreSQL syntax. Fix migrations or use
adapter-specific migrations deliberately and document the difference.

### 3. Transfer data safely

RubyDB `.rdb` files cannot be opened by PostgreSQL. A safe small-dataset flow is:

1. stop writes to the RubyDB application;
2. create a verified RubyDB backup;
3. create the PostgreSQL database and run reviewed migrations;
4. export each table in a deterministic order, including parent tables first;
5. transform types and IDs explicitly;
6. import into PostgreSQL using bound/escaped data or PostgreSQL `COPY`;
7. compare row counts, checksums, foreign keys, indexes, and business totals;
8. run the application test and smoke suite against PostgreSQL; and
9. switch traffic only after the verification report is approved.

For large or live data, use a purpose-built migration process with checkpoints,
retries, idempotency, and a cutover plan. Do not write a one-off script that
silently skips a row or converts an unknown type to text.

### 4. Test production configuration before cutover

```sh
RAILS_ENV=production DATABASE_URL='postgresql://...' bin/rails db:migrate
RAILS_ENV=production DATABASE_URL='postgresql://...' bin/rails db:seed
RAILS_ENV=production DATABASE_URL='postgresql://...' bin/rails test
```

Run this against a restored staging database, not the only production copy.
Keep the RubyDB backup until PostgreSQL row counts and application behavior
have been accepted.

## Part 2B: deploy RubyDB in production

This path runs one managed RubyDB server and connects Rails/Ruby processes to it
over the RubyDB protocol. The application never opens the server’s data file.

### 1. Provision a database host

Install a pinned RubyDB release, create a dedicated service account, and attach
persistent storage. The data directory must survive process restarts and
deploys. Keep backups on a separate system or failure domain.

```sh
gem install rubydb -v 0.1.5
install -d -o rubydb -g rubydb -m 0700 /var/lib/rubydb/data
install -d -o rubydb -g rubydb -m 0750 /var/log/rubydb
```

Use the complete setup in the [production operations guide](../operations/production-guide.md)
for service supervision, TLS, authentication, resource limits, backups, and
monitoring.

### 2. Start the RubyDB server

Use a reviewed production configuration with WAL, authentication, TLS, and
bounded resources:

```sh
rubydb --config /etc/rubydb/production.yml --env production start
```

Keep port `7432` on a private network. Verify the server before connecting the
application:

```sh
rubydb --config /etc/rubydb/production.yml --env production status --json
rubydb --config /etc/rubydb/production.yml --env production doctor --json
```

### 3. Put one RubyDB URL in the application environment

RubyDB supports its own URL format. `rubydbs` enables TLS:

```text
RUBYDB_URL=rubydbs://app_user:URL_ENCODED_PASSWORD@db.internal.example:7432/my_app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Fca.crt
```

Special characters in usernames and passwords must be percent-encoded. Store
the complete value in a secret manager. Do not print it during deploys.

### 4. Configure Rails

```yaml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

Run the migration once from a controlled release job:

```sh
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails runner 'puts User.count'
```

Do not run migrations simultaneously from every web process. Confirm that the
Rails pool fits below the RubyDB server connection limit with room for workers,
monitoring, and administration.

### 5. Configure regular Ruby

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

Use idempotency keys for retried writes. A timeout or broken connection does
not prove that a write was rolled back; check the operation outcome before
retrying a non-idempotent request.

### 6. Perform a production smoke test

Before routing users:

```sh
RAILS_ENV=production bundle exec rails db:migrate:status
RAILS_ENV=production bundle exec rails runner 'puts User.limit(1).to_a.inspect'
rubydb --config /etc/rubydb/production.yml --env production doctor --json
```

Then test one authenticated read, one create/update/delete transaction, one
background job, one backup, and one restore into a separate directory. Confirm
logs, metrics, disk alerts, WAL/checkpoint state, and rollback ownership.

## Render-style cloud deployment

On a platform such as Render, use a private service for the RubyDB server and a
web service for Rails. Attach a persistent disk to the RubyDB service and set
`RUBYDB_URL` on the Rails service. Keep both services in the same region and
use the private hostname. A platform’s default filesystem is often ephemeral;
verify the provider’s storage behavior before using it for database files.

A single persistent disk normally means one RubyDB primary instance. Do not
assume that increasing the web-service instance count creates database
high availability. Maintain external backups and validate failover separately.

## Final beginner checklist

Before calling the app production-ready, confirm:

* the production database choice is written down;
* all application SQL and migrations pass against that database;
* credentials are environment/secret-manager values, not source files;
* RubyDB uses server mode when more than one process connects;
* TLS, authentication, private networking, and least privilege are enabled;
* a verified backup can be restored on another directory or host;
* monitoring and alerts are visible to an on-call owner;
* connection, lock, request, and shutdown timeouts are bounded; and
* rollback, data migration, and incident procedures have been rehearsed.

For deeper details, continue with [Rails compatibility](../rails/compatibility-guide.md),
[production operations](../operations/production-guide.md),
[troubleshooting](../troubleshooting.md), and [debugging](../debugging.md).

