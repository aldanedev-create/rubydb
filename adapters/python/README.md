# rubydb-python

`rubydb-python` is a dependency-free Python DB-API 2.0 client for RubyDB
server mode. It connects over RubyDB’s newline-delimited JSON protocol and
supports TLS URLs, authentication, parameterized queries, prepared statements
through the wire protocol, transactions, timeouts with cancellation, and a
bounded connection pool.

It does not open RubyDB embedded `.rdb` files. An embedded file must have one
Ruby process owner; Python applications use a RubyDB server.

## Install

From PyPI after release:

```sh
python -m pip install rubydb-python
```

From this repository during development:

```sh
cd adapters/python
python -m pip install -e .
```

## Connect and query

```python
import os
import rubydb

with rubydb.connect(os.environ["RUBYDB_URL"]) as connection:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT id, name FROM users WHERE active = ? ORDER BY id",
            [True],
        )
        for row in cursor.fetchall():
            print(row)
```

`rubydb://` is plain TCP for trusted private development networks.
`rubydbs://` enables TLS. Production should use `rubydbs://`, peer
verification, a private network, and a secret manager:

```text
rubydbs://app_user:URL_ENCODED_PASSWORD@db.internal:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

Passwords and private keys must not be committed or printed. The server and
client must use compatible RubyDB protocol versions.

## Transactions and pooling

Connections default to DB-API transaction behavior (`autocommit=False`):

```python
import rubydb

with rubydb.connect("rubydbs://app_user:password@db.internal:7432/app") as db:
    with db.cursor() as cursor:
        cursor.execute(
            "INSERT INTO audit_events (event_name) VALUES (?)",
            ["python-start"],
        )
```

Prepared statements are available when the RubyDB server advertises them:

```python
with rubydb.connect(os.environ["RUBYDB_URL"]) as db:
    statement = db.prepare("SELECT id FROM users WHERE email = ?")
    try:
        with statement.execute(["ada@example.test"]) as cursor:
            print(cursor.fetchone())
    finally:
        statement.close()
```

For concurrent Python workers, use a bounded pool. The pool creates at most
`max_size` server sessions:

```python
from rubydb import ConnectionPool

pool = ConnectionPool(
    "rubydbs://app_user:password@db.internal:7432/app",
    min_size=1,
    max_size=8,
)
try:
    with pool.connection() as db:
        with db.cursor() as cursor:
            cursor.execute("SELECT 1")
            print(cursor.fetchone())
finally:
    pool.close()
```

## Test and package

Run the dependency-free unit tests:

```sh
cd adapters/python
python -m unittest discover -s tests -v
```

Build and inspect the distribution:

```sh
python -m pip install --upgrade build twine
python -m build
python -m twine check dist/*
```

Publish only after CI, protocol integration tests against a real RubyDB
server, TLS tests, and application validation pass:

```sh
python -m twine upload dist/*
```

Configure PyPI credentials through trusted publishing or a protected token;
never put a token in this repository or in a committed shell script.

## Example applications

The repository includes two small applications that use this adapter against a
real RubyDB server:

- [`examples/python_flask`](../../examples/python_flask) — synchronous Flask
  JSON API with live tests.
- [`examples/python_flaxon`](../../examples/python_flaxon) — async Flaxon JSON
  API using `asyncio.to_thread` for database calls, with live tests.

Each example documents server startup, `RUBYDB_URL`, schema initialization,
development commands, and production boundaries. Run the tests with a live
RubyDB server before deploying an application-specific integration.

## Compatibility boundary

This is a RubyDB client, not a PostgreSQL driver. It does not provide
PostgreSQL SQL compatibility, embedded-mode access, or automatic failover. Use
PostgreSQL’s Python drivers for PostgreSQL applications. See the repository’s
[wire protocol](../../docs/server/protocol.md), [production operations
guide](../../docs/operations/production-guide.md), and [SQL compatibility
guide](../../docs/sql/compatibility-guide.md).
