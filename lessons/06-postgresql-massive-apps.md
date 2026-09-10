# Lesson 6: PostgreSQL for large applications

For a massive or business-critical application, PostgreSQL is usually the
safer system of record. It has a mature ecosystem of managed services,
replication, backup tooling, connection poolers, extensions, observability,
and Rails deployment experience. Choose it when many app instances, large
tables, broad SQL compatibility, or a large operations team are requirements.

RubyDB can still be valuable during development or as a bounded service. The
choice is architectural: do not make one database responsible for a workload
whose concurrency, failover, or SQL requirements it has not passed.

## Rails configuration

Add the PostgreSQL adapter:

```ruby
# Gemfile
gem "pg"
```

Configure production with the provider’s secret connection URL:

```yaml
# config/database.yml
production:
  url: <%= ENV.fetch("DATABASE_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
  checkout_timeout: <%= ENV.fetch("DB_CHECKOUT_TIMEOUT", "5") %>
```

The URL is normally shaped like this; use a generated password rather than
the sample credentials:

```text
postgresql://app_user:URL_ENCODED_PASSWORD@postgres.internal:5432/app_production
```

Run migrations from one controlled release job:

```sh
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails db:migrate:status
```

Do not run `db:migrate` concurrently from every web instance.

## Local parity

Use a pinned PostgreSQL major version locally and in CI:

```sh
docker run --name lesson-postgres \
  --env POSTGRES_PASSWORD=devpassword \
  --env POSTGRES_DB=app_development \
  --publish 5432:5432 \
  --detach postgres:16

DATABASE_URL=postgresql://postgres:devpassword@127.0.0.1:5432/app_development \
  bundle exec rails db:migrate
```

The password is for a disposable local container only. Use secret storage in
CI and production.

## Connection pool sizing

Each Rails process can open up to its configured pool size. A first estimate is
`web_processes * pool_size + worker_pools + admin_headroom`, but the database
provider’s connection limit and actual workload decide the safe value. Measure
queue time and query latency. A pool setting that is larger than the database
limit causes timeouts rather than more throughput.

For larger deployments, evaluate a PostgreSQL-aware connection pooler and your
provider’s read-replica strategy. Test transactions, prepared statements,
failover behavior, and session settings with the pooler before production.

## SQL and data features

PostgreSQL is appropriate when the application relies on PostgreSQL-specific
types, functions, extensions, advanced indexing, row-level locking, or complex
query plans. Keep those choices explicit in migrations and tests. RubyDB’s
adapter is not a promise that PostgreSQL SQL can run unchanged on RubyDB.

If the application starts on RubyDB and moves to PostgreSQL, run reviewed
migrations on a new PostgreSQL database, export and transform data explicitly,
compare row counts and business totals, and test the cutover. An environment
variable changes where new connections go; it does not convert an `.rdb` file.

## Checkpoint

The checkpoint passes when the production Rails build can create a PostgreSQL
database, apply migrations once, run the full application test suite, take a
provider-supported backup, restore a staging copy, and demonstrate the
connection pool remains below the provider limit. Continue to [lesson 7](07-hybrid-microservices.md)
for a hybrid design using both databases responsibly.
