# @dbs/rubydb

`@dbs/rubydb` is a dependency-free Node.js and TypeScript client for the
RubyDB server protocol. It uses `rubydb://` for trusted private networks and
`rubydbs://` for TLS connections. It does not open embedded `.rdb` files.

> npm package names must be lowercase, so the publishable name is
> `@dbs/rubydb`, the lowercase form of `@dbS/rubydb`. The `dbs` scope must be
> owned by your npm user or organization before publishing.

## Install

```sh
npm install @dbs/rubydb
```

## Query RubyDB

```ts
import { connect } from "@dbs/rubydb";

const db = await connect(process.env.RUBYDB_URL!);
try {
  const result = await db.query(
    "SELECT id, name FROM users WHERE active = ? ORDER BY id",
    [true],
  );
  console.log(result.rows);
} finally {
  await db.close();
}
```

The client uses `?` parameters and sends values separately from SQL. Do not
build SQL by concatenating user input.

## Transactions and prepared statements

Connections default to `autocommit: false` and begin a transaction before the
first query. Commit or roll back explicitly:

```ts
const db = await connect({
  host: "127.0.0.1",
  port: 7432,
  username: "service_user",
  password: process.env.RUBYDB_PASSWORD,
  database: "orders",
});
try {
  const statement = await db.prepare(
    "INSERT INTO audit_events (event_name) VALUES (?)",
  );
  await statement.execute(["order.created"]);
  await statement.close();
  await db.commit();
} catch (error) {
  await db.rollback();
  throw error;
} finally {
  await db.close();
}
```

## Pooling

Use one bounded pool per application process. A connection is leased for one
operation and must be released by `use`:

```ts
import { ConnectionPool } from "@dbs/rubydb";

const pool = await ConnectionPool.create(process.env.RUBYDB_URL!, {
  minSize: 1,
  maxSize: 8,
});
try {
  const rows = await pool.use(async (db) => {
    const result = await db.query("SELECT id FROM jobs WHERE state = ?", ["ready"]);
    return result.rows;
  });
  console.log(rows);
} finally {
  await pool.close();
}
```

## TLS and timeouts

Production clients should use a TLS URL with peer verification and a bounded
timeout. Certificate files can be supplied through URL query parameters:

```text
rubydbs://service_user:URL_ENCODED_PASSWORD@db.internal:7432/orders?timeout=5&verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

An expired request sends a wire-level cancellation to RubyDB and raises
`TimeoutError`. Treat a timed-out write as possibly committed and use an
idempotency key before retrying it.

## Development and tests

```sh
npm install
npm test
npm run pack:check
```

The unit tests use a protocol fixture. Run the live test against a RubyDB
server for real TCP validation:

```sh
RUBYDB_URL=rubydb://rubydb@127.0.0.1:7432/rubydb npm test
```

On PowerShell:

```powershell
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb"
npm test
```

## Publish

Build and inspect the package first:

```sh
npm run publish:check
npm publish --access public
```

Use npm Trusted Publishing from CI or an npm token stored in protected secret
storage. Never commit `.npmrc` credentials or tokens. Publishing requires
permission to create packages in the `@dbs` scope.

This package is a RubyDB client, not a PostgreSQL driver and not an embedded
file adapter. Pin the client and RubyDB server versions together and validate
your application's SQL, migrations, TLS, backup, retry, and failover behavior.
