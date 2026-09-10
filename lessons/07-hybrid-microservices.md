# Lesson 7: a hybrid microservice architecture

A practical RubyDB architecture is to keep the large shared business system
on PostgreSQL and use RubyDB for a small service with a narrow responsibility.
Examples include a local catalog, a bounded document/index service, an
internal workflow, or a tenant-isolated tool whose SQL and recovery needs have
been validated.

## Give each service ownership

```text
Rails monolith / public API
    |
    +--> PostgreSQL: users, billing, orders, reporting
    |
    +--> RubyDB service API: bounded internal records
                 |
                 +--> one RubyDB server and persistent data directory
```

The services communicate through an API or an event contract. They do not
share an embedded file and they do not write directly into each other’s tables.
Each service owns its migrations, credentials, backups, alerts, and recovery
runbook.

## Ruby client for a service

```ruby
# app/services/catalog_store.rb
require "rubydb"

class CatalogStore
  def initialize(url: ENV.fetch("RUBYDB_URL"))
    @client = RubyDB::Client::Client.new(url: url)
  end

  def find(code)
    result = @client.query(
      "SELECT code, title FROM catalog_items WHERE code = ?",
      [code]
    )
    result.to_a.first
  end

  def close
    @client.disconnect
  end
end
```

Use the actual client API in the version pinned by the service and add tests
for connection failures, timeouts, duplicate requests, and empty results. In a
long-running app, put client lifecycle management in the application’s
dependency/container layer and close it during shutdown.

## Python services with the RubyDB adapter

Python applications connect to RubyDB server mode through the published
`rubydb-python` DB-API 2.0 adapter. The Python process must not open an
embedded `.rdb` file. Put the server URL in a secret-managed environment
variable:

```powershell
$env:RUBYDB_URL = "rubydbs://service_user:URL_ENCODED_PASSWORD@rubydb.internal:7432/orders?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt"
python -m pip install rubydb-python
```

Use parameterized queries and a bounded pool in workers:

```python
import os
from rubydb import ConnectionPool

pool = ConnectionPool(os.environ["RUBYDB_URL"], min_size=1, max_size=8)
try:
    with pool.connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT id, status FROM jobs WHERE account_id = ?",
                [account_id],
            )
            rows = cursor.fetchall()
finally:
    pool.close()
```

The adapter is synchronous DB-API code. In an async framework such as Flaxon,
run database calls in a worker thread so a slow query does not block the event
loop:

```python
import asyncio
from rubydb import connect

async def load_jobs(url):
    def query():
        with connect(url, timeout=5) as db:
            with db.cursor() as cursor:
                cursor.execute("SELECT id, status FROM jobs ORDER BY id")
                return cursor.fetchall()

    return await asyncio.to_thread(query)
```

Run the complete examples in `examples/python_flask` and
`examples/python_flaxon`. Both examples use real RubyDB TCP traffic and have
live integration tests; they are intentionally small starting points, not a
replacement for application-specific authorization, migrations, backups,
timeouts, monitoring, and load testing.

## Node.js and TypeScript services

Node services use the `@dbs/rubydb` package over the same RubyDB server
protocol:

```sh
npm install @dbs/rubydb
```

```ts
import { connect } from "@dbs/rubydb";

const db = await connect(process.env.RUBYDB_URL!);
try {
  const result = await db.query(
    "SELECT id, state FROM jobs WHERE account_id = ?",
    [accountId],
  );
  console.log(result.rows);
} finally {
  await db.close();
}
```

Use `ConnectionPool` for concurrent workers, keep the pool bounded per process,
and use `rubydbs://` with peer verification in production. The package is
TypeScript-first, supports prepared statements, transactions, timeouts with
wire cancellation, and does not access embedded database files. See
`adapters/node/README.md` for the full Node release and operations boundary.

## A small Rails service

```yaml
# service/config/database.yml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

Keep the API idempotent. A client timeout can happen after the server commits
a write, so a retry must use an idempotency key or first check the operation’s
result. For cross-service workflows, record an outbox/event in the owning
system and design consumers to tolerate duplicate delivery.

## What belongs where

Keep users, payments, orders, and cross-tenant reporting in PostgreSQL when
they need shared relational consistency and broad analytical tooling. Keep
RubyDB data that can be independently backed up, restored, migrated, and
reconciled. Do not split a single atomic business transaction across the two
databases unless you have designed and tested a distributed workflow.

## Failure and deployment rules

* Deploy the RubyDB service with a persistent volume and one server owner.
* Make the service private; clients use TLS and least-privilege credentials.
* Set bounded connection and request timeouts and expose a useful health probe.
* Retry only idempotent operations, with backoff and a maximum attempt count.
* Maintain a PostgreSQL and RubyDB restore drill independently.
* Version the API/event contract before changing either database schema.

## Checkpoint

The checkpoint passes when each data set has one owner, the API can tolerate a
restarted database service, duplicate requests do not create duplicate business
records, and the two systems can be restored independently. Continue to [lesson 8](08-migrations-backups-recovery.md)
for migration and recovery drills.
