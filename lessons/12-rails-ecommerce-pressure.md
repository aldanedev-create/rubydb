# Lesson 12: Build and pressure-test a Rails shop with RubyDB

This lesson uses the runnable application in
[`examples/rails_ecommerce`](../examples/rails_ecommerce/). It is intentionally
small enough to understand, but it exercises the database paths that usually
matter in a commerce service:

- catalog filters, ordering, limits, and compound indexes;
- grouped order summaries;
- customer/order/item associations and eager loading;
- a transaction that creates an order and updates inventory;
- direct ActiveRecord pressure and HTTP request pressure.

The example is a validation tool. A successful local run proves that this
specific application and workload work together; it is not a capacity promise
for every Rails application or deployment.

## 1. Copy the example and install it

From a checkout of RubyDB:

```sh
cd examples/rails_ecommerce
bundle install
```

The example uses local paths to the RubyDB engine and ActiveRecord adapter, so
you can test the code currently checked out without publishing a new gem.
When using released gems in your own application, use pinned versions instead:

```ruby
gem "rubydb", "0.1.7"
gem "rubydb-activerecord", "0.1.3"
```

## 2. Create and seed the local database

Embedded mode is the easiest local development setup. RubyDB creates the file
under `examples/rails_ecommerce/tmp/` and Rails talks to it through the real
ActiveRecord adapter. The example pins embedded Puma and the ActiveRecord pool
to one thread/connection because one embedded RubyDB path has one process-local
owner:

```sh
bundle exec rails db:prepare
RUBYDB_PRODUCTS=500 RUBYDB_CUSTOMERS=100 RUBYDB_ORDERS=1000 bundle exec rails db:seed
bundle exec ruby script/smoke.rb
```

PowerShell:

```powershell
$env:RUBYDB_PRODUCTS = "500"
$env:RUBYDB_CUSTOMERS = "100"
$env:RUBYDB_ORDERS = "1000"
bundle exec rails db:prepare
bundle exec rails db:seed
bundle exec ruby script/smoke.rb
```

The seed is deterministic. Change the three environment variables to create a
larger fixture without changing the application:

```sh
RUBYDB_PRODUCTS=10000 RUBYDB_CUSTOMERS=2000 RUBYDB_ORDERS=25000 bundle exec rails db:seed
```

## 3. Understand the Rails queries

The catalog action uses a filtered and ordered relation:

```ruby
Product.active
  .in_category(params[:category])
  .order(price_cents: :asc)
  .limit(50)
```

It also executes a grouped aggregate for the category navigation:

```ruby
Product.active.group(:category).count
```

The smoke test exercises eager loading and a grouped order query:

```ruby
Order.completed.group(:status).count
Order.includes(:customer, :order_items).order(id: :desc).first
```

The order action keeps the business write atomic:

```ruby
Order.transaction do
  order = customer.orders.create!(status: "paid", total_cents: total)
  order.order_items.create!(product: product, quantity: quantity, unit_price_cents: price)
  product.update!(stock: product.stock - quantity)
end
```

In a real store, add an explicit inventory reservation strategy, idempotency
keys, payment authorization boundaries, audit records, and a concurrency test
for overselling. The small example keeps the business flow visible for
learning.

## 4. Run direct database pressure

Run the database workload without HTTP overhead:

```sh
RUBYDB_PRESSURE_OPERATIONS=1000 bundle exec ruby script/pressure.rb
```

The output is JSON containing completed operations, errors, throughput, and
p50/p95/p99 latency. The workload randomly exercises catalog reads, a `LIKE`
filter, grouped order counts, and eager-loaded order history.

To add transaction writes:

```sh
RUBYDB_PRESSURE_MODE=mixed \
RUBYDB_PRESSURE_WRITE_RATIO=0.10 \
RUBYDB_PRESSURE_OPERATIONS=1000 \
bundle exec ruby script/pressure.rb
```

The script exits non-zero when any operation fails. Treat the first error as a
correctness issue to investigate, not as an acceptable benchmark result.

## 5. Run the Rails app and HTTP pressure

Start the app:

```sh
bundle exec rails server -b 127.0.0.1 -p 3002
```

In a second terminal, send concurrent requests to the JSON catalog endpoint:

```sh
RUBYDB_HTTP_THREADS=8 \
RUBYDB_HTTP_REQUESTS=500 \
bundle exec ruby script/http_pressure.rb
```

PowerShell:

```powershell
$env:RUBYDB_HTTP_THREADS = "8"
$env:RUBYDB_HTTP_REQUESTS = "500"
bundle exec ruby script/http_pressure.rb
```

This measures Rails routing, controller work, serialization, and database
reads together. It does not replace a load test that runs from another host,
but it gives a reproducible local baseline.

## 6. Test the multi-process topology

Embedded mode is for one process owning one database path. For concurrent web
traffic, web workers,
job workers, or more than one host, run a RubyDB server and connect over the
protocol. From the example directory, start the local server using the
repository executable:

```sh
mkdir -p tmp/rubydb-commerce-server
bundle exec ruby ../../exe/rubydb start \
  --host 127.0.0.1 \
  --port 7432 \
  --data-dir tmp/rubydb-commerce-server \
  --log-dir tmp/rubydb-commerce-server/log
```

In another terminal, migrate and seed through the server:

```sh
RUBYDB_EMBEDDED=false \
RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
bundle exec rails db:prepare

RUBYDB_EMBEDDED=false \
RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
RUBYDB_PRODUCTS=1000 RUBYDB_CUSTOMERS=200 RUBYDB_ORDERS=5000 \
bundle exec rails db:seed
```

Then run several Rails database workers against the server:

```sh
RUBYDB_EMBEDDED=false \
RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
RAILS_MAX_THREADS=8 \
RUBYDB_PRESSURE_THREADS=8 \
RUBYDB_PRESSURE_OPERATIONS=2000 \
bundle exec ruby script/pressure.rb
```

For TLS, use a `rubydbs://` URL and configure certificate verification. In a
real deployment, inject the URL through a secret manager; do not commit a
password into `database.yml` or a benchmark script.

## 7. Read the results correctly

Record the JSON output with the Git commit and fixture size. Compare:

1. p50 for normal user requests;
2. p95 and p99 for tail latency under pressure;
3. throughput and error count;
4. server CPU, memory, WAL growth, disk space, and rejected connections;
5. results before and after enabling an accelerator policy.

Do not compare one tiny in-memory run with a production claim. Go acceleration
is adaptive: small queries can stay in Ruby when process/protocol overhead is
larger than the work, while eligible large immutable-snapshot operations can be
accelerated. Correct results, durable commits, and bounded resource use come
before a lower benchmark number.

## 8. Run the accelerator A/B check

From the repository root, run the same 10,000-row workload with a Ruby-only
baseline and the required Go worker:

```powershell
$env:RUBYDB_ACCELERATOR_ROWS = "10000"
$env:RUBYDB_ACCELERATOR_ITERATIONS = "5"
$env:RUBYDB_ACCELERATOR_THREADS = "4"
$env:RUBYDB_ACCELERATOR_REQUESTS = "5"
bundle exec ruby benchmarks/go_accelerator.rb
```

The benchmark verifies the row result before and during measurement, performs
an explicit worker restart, and reports p50/p95/p99 latency, throughput, CPU,
RSS, concurrent-request errors, worker starts/restarts/failures, and a speed
gate. `performance_gate_passed` must be `true` for this exact workload and
machine before selecting `RUBYDB_ACCELERATOR=required`; otherwise leave the
policy at `auto` or `off`. A Go worker can be correct but slower when the
workload is dominated by copying Ruby objects through the process boundary.

For larger Rails pressure, use at least 10,000 products and 10,000 orders,
then run the direct and server-mode pressure commands above. Include the
result JSON, commit, Ruby/Rails versions, and host metrics in the performance
record.

## 9. Production checklist for this app

Before using the pattern for a real service:

- pin Ruby, Rails, RubyDB, and adapter versions;
- use server mode for multiple processes and hosts;
- run migrations against a backup or restored staging copy first;
- configure TLS, authentication, connection limits, timeouts, and monitoring;
- test idempotent order creation and payment retries;
- test inventory contention and deadlock/timeout behavior;
- run backup, restore, restart, and disk-space drills;
- establish an application-specific p95/p99 SLO with representative data;
- keep PostgreSQL as the comparison target when the application needs its
  broader SQL dialect, ecosystem, or large-scale operational guarantees.

This lesson makes RubyDB easy to try locally while keeping the boundary clear:
the benchmark measures the features the example actually uses, and production
readiness still requires validation of the exact application and topology.
