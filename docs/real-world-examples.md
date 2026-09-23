# Real-world copy-and-paste cookbook

These examples use a small order service because it exercises the common
patterns in a web application: a schema, an indexed lookup, an atomic write,
a report, and a production connection. Run the examples against the exact
RubyDB version you plan to deploy.

## Choose a topology first

| Situation | Use | Important rule |
| --- | --- | --- |
| Script, CLI tool, single local Rails process | Embedded file | Exactly one process owns the `.rdb` path. |
| Web processes, workers, Python, or Node clients | RubyDB server | Every client connects through `RUBYDB_URL`; clients never open the server data file. |
| Large Rails application or unvalidated SQL/features | PostgreSQL in production | Validate migrations and generated SQL before switching environments. |

RubyDB is not a drop-in implementation of every PostgreSQL, MySQL, or SQLite
feature. Check the [SQL compatibility contract](sql/compatibility.md) before
depending on a dialect feature.

## 1. Embedded Ruby order script

Install the gem, create a file outside source control, and run this as one
process. The API is intentionally SQLite-like: `RubyDB.open` opens or creates
the local database file.

```sh
gem install rubydb
mkdir -p tmp
```

```ruby
# order_service.rb
require "rubydb"

db = RubyDB.open("tmp/orders.rdb")
begin
  db.execute <<~SQL
    CREATE TABLE IF NOT EXISTS products (
      id INTEGER PRIMARY KEY,
      sku TEXT UNIQUE NOT NULL,
      name TEXT NOT NULL,
      price_cents INTEGER NOT NULL,
      stock INTEGER NOT NULL
    )
  SQL
  db.execute <<~SQL
    CREATE TABLE IF NOT EXISTS orders (
      id INTEGER PRIMARY KEY,
      customer_email TEXT NOT NULL,
      total_cents INTEGER NOT NULL,
      created_at TIMESTAMP NOT NULL
    )
  SQL
  db.execute "CREATE INDEX IF NOT EXISTS products_sku_idx ON products (sku)"

  # Hash rows avoid constructing SQL from application input. Batch seeding
  # validates and WAL-logs each row while reducing metadata publication work.
  db.insert_many("products", [
    { id: 1, sku: "coffee-1kg", name: "Coffee 1kg", price_cents: 1899, stock: 20 },
    { id: 2, sku: "tea-200g", name: "Tea 200g", price_cents: 899, stock: 35 }
  ])

  db.transaction do
    product = db.query("SELECT id, price_cents, stock FROM products WHERE sku = 'coffee-1kg'").first
    raise "product is unavailable" unless product && product[:stock].to_i.positive?

    db.execute("UPDATE products SET stock = stock - 1 WHERE id = #{product[:id].to_i}")
    db.execute <<~SQL
      INSERT INTO orders (id, customer_email, total_cents, created_at)
      VALUES (1001, 'ada@example.test', #{product[:price_cents].to_i}, '2026-09-23 12:00:00')
    SQL
  end

  p db.query("SELECT customer_email, total_cents FROM orders ORDER BY id")
ensure
  db.close
end
```

```sh
ruby order_service.rb
```

This embedded sample deliberately uses fixed, trusted values. Do not interpolate
HTTP request values into SQL. For user-provided values, use a server client and
parameterized queries as shown below, or use ActiveRecord.

## 2. RubyDB server for a web service

Use server mode whenever several processes need the same database: for example
Puma workers, a job process, a Rails console, Python workers, or Node services.
Provision a private host/volume and start the database under a service manager.

```sh
rubydb init --name orders --dir /var/lib/rubydb/data
rubydb --env production start \
  --host 127.0.0.1 \
  --port 7432 \
  --data-dir /var/lib/rubydb/data \
  --log-dir /var/log/rubydb \
  --pid-file /run/rubydb.pid
```

Set the endpoint through the platform secret manager, not a committed `.env`
file. In production use TLS (`rubydbs`) and enable certificate verification:

```text
RUBYDB_URL=rubydbs://orders_app:URL_ENCODED_PASSWORD@db.internal:7432/orders?timeout=5&verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

The application connects using that one value:

```ruby
require "rubydb"

client = RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL"))
begin
  # Values travel separately from the SQL statement.
  result = client.query(
    "SELECT id, sku, stock FROM products WHERE sku = ?",
    ["coffee-1kg"],
    timeout: 2
  )
  p result.to_hash
ensure
  client.disconnect
end
```

Treat a timeout during a write as *possibly committed*. Include an application
idempotency key (for example, `orders.request_id UNIQUE`) and make retries
safe, rather than assuming a network error rolled back the transaction.

## 3. Rails local development and production configuration

Add RubyDB and the ActiveRecord adapter to the application:

```ruby
# Gemfile
gem "rubydb"
gem "rubydb-activerecord"
gem "pg" # retain when PostgreSQL is the production target
```

For local development, give each environment a separate, single-owner file:

```yaml
# config/database.yml
development:
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/rubydb_development.rdb") %>

test:
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/rubydb_test.rdb") %>

production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

Create a typical model and migration, then run it once in the release job:

```ruby
# db/migrate/20260923000000_create_orders.rb
class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.string :customer_email, null: false
      t.integer :total_cents, null: false
      t.string :request_id, null: false
      t.timestamps
    end
    add_index :orders, :request_id, unique: true
  end
end
```

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  validates :customer_email, :request_id, presence: true
  validates :total_cents, numericality: { greater_than_or_equal_to: 0 }
end
```

```sh
bin/rails db:migrate
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails runner 'puts Order.count'
```

Do not let every web process run migrations concurrently. Test the exact Rails
version, generated SQL, associations, eager loads, and populated-table
migrations before deciding RubyDB is an appropriate production database for
the application.

## 4. Query a report through the CLI

Use the shell for a local, controlled inspection—not as a replacement for an
application-level authorization policy:

```sh
rubydb shell --database /var/lib/rubydb/data/orders.rdb
```

At the shell prompt, copy this sales report:

```sql
SELECT customer_email, COUNT(*) AS order_count, SUM(total_cents) AS revenue_cents
FROM orders
GROUP BY customer_email
HAVING COUNT(*) >= 2
ORDER BY revenue_cents DESC;
```

Use `EXPLAIN` before optimizing a representative query, then add/validate an
index only after measuring the workload:

```sql
EXPLAIN SELECT id, sku, stock FROM products WHERE sku = 'coffee-1kg';
CREATE INDEX IF NOT EXISTS products_sku_idx ON products (sku);
```

## 5. Backup, restore, and a representative workload

Run these in staging first and replace the paths with approved persistent
storage. A backup that has not been restored and queried is not a verified
backup.

```sh
mkdir -p /srv/rubydb-backups
rubydb backup --database /var/lib/rubydb/data/orders.rdb --output /srv/rubydb-backups/orders.rdb.backup
rubydb restore --input /srv/rubydb-backups/orders.rdb.backup --database /srv/rubydb-restore/orders.rdb
rubydb doctor --database /srv/rubydb-restore/orders.rdb --json
rubydb export --database /srv/rubydb-restore/orders.rdb --table orders --format csv --out /tmp/orders-restore-check.csv
```

Run a deterministic concurrency workload on the same filesystem and class of
machine as the intended deployment. It is evidence for that workload, not a
capacity guarantee:

```sh
RUBYDB_WORKLOAD_PATH=/srv/rubydb-staging/workload.rdb \
RUBYDB_WORKLOAD_THREADS=16 \
RUBYDB_WORKLOAD_OPERATIONS=10000 \
ruby benchmarks/concurrent_workload.rb
```

For Go accelerator verification, compare the same workload/query in both
modes and keep the result artifact with the release evidence:

```sh
RUBYDB_ACCELERATOR=off rubydb accelerator --ping --json
RUBYDB_ACCELERATOR=required rubydb accelerator --ping --json
```

The accelerator automatically falls back in `auto` mode when it cannot prove a
safe, measured win. It does not make every database workload faster and it
does not replace indexing, schema design, or capacity testing.

## 6. Python and Node clients

These adapters are server clients; they do not open an embedded `.rdb` file.

```sh
python -m pip install rubydb-python
npm install rubydb-node
```

```python
# Python
import os
import rubydb

with rubydb.connect(os.environ["RUBYDB_URL"]) as connection:
    with connection.cursor() as cursor:
        cursor.execute("SELECT id FROM orders WHERE request_id = ?", ["req-1001"])
        print(cursor.fetchone())
```

```ts
// TypeScript
import { connect } from "rubydb-node";

const db = await connect(process.env.RUBYDB_URL!);
try {
  console.log((await db.query("SELECT id FROM orders WHERE request_id = ?", ["req-1001"])).rows);
} finally {
  await db.close();
}
```

Read the adapter READMEs before deployment: [Python](../adapters/python/README.md)
and [Node](../adapters/node/README.md). Pin client and server versions together,
use TLS, bound pool sizes, and test timeouts/retries against a real server.
