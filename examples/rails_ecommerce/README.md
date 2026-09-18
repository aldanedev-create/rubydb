# Rails e-commerce pressure example

This is a deliberately small Rails 7.2 shop used to exercise RubyDB with real
ActiveRecord traffic. It contains:

- products, customers, orders, and order items;
- unique and compound indexes plus foreign keys;
- catalog filtering, ordering, grouping, joins, and eager loading;
- an order transaction that writes an order, line item, and inventory update;
- deterministic seed data;
- direct ActiveRecord pressure testing and HTTP pressure testing.

It is a benchmark and learning application, not a complete store. Do not use
the demo secret, sample customer, or embedded database path as a production
configuration.

## 1. Run it locally

From this directory:

```sh
bundle install
bundle exec rails db:prepare
RUBYDB_PRODUCTS=500 RUBYDB_CUSTOMERS=100 RUBYDB_ORDERS=1000 bundle exec rails db:seed
bundle exec ruby script/smoke.rb
bundle exec rails server -b 127.0.0.1 -p 3002
```

On PowerShell, the seed command is:

```powershell
$env:RUBYDB_PRODUCTS = "500"
$env:RUBYDB_CUSTOMERS = "100"
$env:RUBYDB_ORDERS = "1000"
bundle exec rails db:seed
```

Open <http://127.0.0.1:3002/>. The JSON catalog endpoint is
<http://127.0.0.1:3002/products.json>.

## 2. Run a direct database workload

The default is a safe, single-thread embedded read workload:

```sh
RUBYDB_PRESSURE_OPERATIONS=1000 bundle exec ruby script/pressure.rb
```

It reports completed operations, errors, throughput, and p50/p95/p99 latency.
The workload uses real Rails queries; it does not mock the adapter or database.

To include order transactions in a local single-owner run:

```sh
RUBYDB_PRESSURE_MODE=mixed RUBYDB_PRESSURE_WRITE_RATIO=0.10 RUBYDB_PRESSURE_OPERATIONS=500 bundle exec ruby script/pressure.rb
```

Embedded RubyDB owns one database path inside one process. This example pins
embedded Puma and the ActiveRecord pool to one thread/connection. Do not
interpret that as a multi-process capacity result. For concurrent pressure,
use the server mode below.

## 3. Run HTTP pressure

With the Rails server running in another terminal:

```sh
RUBYDB_HTTP_THREADS=8 RUBYDB_HTTP_REQUESTS=500 bundle exec ruby script/http_pressure.rb
```

PowerShell:

```powershell
$env:RUBYDB_HTTP_THREADS = "8"
$env:RUBYDB_HTTP_REQUESTS = "500"
bundle exec ruby script/http_pressure.rb
```

This measures the complete Rails request path and fails with a non-zero exit
status if any request is not HTTP 200. Use a real load generator as a second
validation step when certifying a deployment; this small script is intended to
be portable and copy-paste friendly.

## 4. Test concurrent server/client traffic

Run a RubyDB server from the repository root in a separate terminal:

```sh
mkdir -p tmp/rubydb-commerce-server
bundle exec ruby ../../exe/rubydb start --host 127.0.0.1 --port 7432 \
  --data-dir tmp/rubydb-commerce-server --log-dir tmp/rubydb-commerce-server/log
```

From this app directory, use the server connection for migrations and seeds:

```sh
RUBYDB_EMBEDDED=false \
RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
bundle exec rails db:prepare
RUBYDB_EMBEDDED=false \
RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
RUBYDB_PRODUCTS=500 RUBYDB_CUSTOMERS=100 RUBYDB_ORDERS=1000 \
bundle exec rails db:seed
```

PowerShell:

```powershell
$env:RUBYDB_EMBEDDED = "false"
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb"
bundle exec rails db:prepare
bundle exec rails db:seed
```

Then run concurrent database pressure:

```sh
RUBYDB_EMBEDDED=false RUBYDB_URL='rubydb://rubydb@127.0.0.1:7432/rubydb' \
RAILS_MAX_THREADS=8 RUBYDB_PRESSURE_THREADS=8 RUBYDB_PRESSURE_OPERATIONS=1000 \
bundle exec ruby script/pressure.rb
```

For a production-like Rails process, keep `RUBYDB_URL` in the platform secret
store, use `rubydbs://` with TLS, and size the Rails pool below the server's
connection limit. Never mount the same embedded database file into several web
or worker processes.

## 5. What to compare

Run the same seed size and workload after every engine or adapter change. Save
the JSON output with the commit identifier and record:

- p50, p95, and p99 latency;
- completed operations and errors;
- throughput;
- RubyDB server CPU, memory, WAL growth, and disk space;
- worker restarts, timeouts, and rejected connections.

The Go accelerator is an adaptive optimization for eligible RubyDB execution
paths. This Rails example validates the ActiveRecord/server path as a whole;
it must not claim that every ActiveRecord query automatically runs in Go or
that a small workload will always be faster. Compare results and correctness
before changing the policy or declaring a performance improvement.

## 6. Run the Ruby-versus-Go accelerator benchmark

From the repository root, run the controlled 10,000-row A/B benchmark:

```powershell
$env:RUBYDB_ACCELERATOR_ROWS = "10000"
$env:RUBYDB_ACCELERATOR_ITERATIONS = "5"
$env:RUBYDB_ACCELERATOR_THREADS = "4"
$env:RUBYDB_ACCELERATOR_REQUESTS = "5"
bundle exec ruby benchmarks/go_accelerator.rb
```

The benchmark runs the same filter/order workload through a Ruby-only baseline
and `mode: required` through the bundled Go worker. It checks returned rows,
performs a worker restart, sends concurrent requests, and reports p50/p95/p99,
throughput, CPU, RSS, worker restarts, worker failures, and errors. A result is
not a production speed claim: the Go path can be slower when copying Ruby rows
over the private protocol. Keep Go in `auto` until the representative workload
shows an equivalent result and a measurable p95 improvement.

To exercise larger Rails fixtures before pressure testing:

```powershell
$env:RUBYDB_PRODUCTS = "10000"
$env:RUBYDB_CUSTOMERS = "2000"
$env:RUBYDB_ORDERS = "10000"
bundle exec rails db:seed
$env:RUBYDB_PRESSURE_THREADS = "8"
$env:RUBYDB_PRESSURE_OPERATIONS = "2000"
$env:RUBYDB_PRESSURE_MODE = "read"
bundle exec ruby script/pressure.rb
```

Run the same fixture in server mode for multi-process traffic. Save the JSON
results with the RubyDB commit, Ruby/Rails versions, OS, CPU, memory, and disk
details; do not compare runs with different data sizes.
