# Lesson 11 — Build a RubyDB adapter for your community

This lesson is for a developer who wants to make RubyDB available to another
language or framework community. The goal is a real, supportable adapter that
can be released independently—not a thin helper that concatenates SQL.

RubyDB adapters connect to a running RubyDB server. They do not open `.rdb`
files directly. One Ruby process owns an embedded database path; a Python,
Node.js, Go, Java, Rust, or framework application should connect to RubyDB in
server mode.

## 1. Choose the community and the support boundary

Write this down before coding:

```text
Adapter:       rubydb-example
Language:      Example 1.0+
Framework:     Example Framework 4.x+
RubyDB:        0.1.x
Transport:     rubydb:// for development, rubydbs:// for production
API:           query, parameters, transactions, prepared statements, pooling
```

Start with a narrow, honest support matrix. A language driver, an ORM adapter,
and a migration tool have different responsibilities:

- A language driver owns connections, parameters, results, errors, deadlines,
  cancellation, transactions, TLS, and resource cleanup.
- An ORM adapter maps the ORM's query, type, transaction, schema, and pooling
  APIs to the driver. It must not claim that RubyDB supports another database's
  dialect just because the ORM has a familiar adapter name.
- A framework integration owns configuration, lifecycle hooks, health checks,
  logging, and deployment conventions for that framework.

Do not promise PostgreSQL, MySQL, or SQLite compatibility unless the exact
syntax and behavior has been implemented and tested. Link users to RubyDB's
[SQL compatibility guide](../docs/sql/compatibility-guide.md) and state which
features your adapter supports.

## 2. Study the reference implementations

Use the repository's adapters as working references:

- [`adapters/python`](../adapters/python) demonstrates a DB-API 2.0 client.
- [`adapters/rubydb`](../adapters/rubydb) demonstrates a TypeScript client,
  promises, TLS, pooling, prepared statements, and timeout cancellation.
- [`adapters/activerecord`](../adapters/activerecord) demonstrates a Ruby ORM
  integration and Rails schema behavior.

Read the [wire protocol guide](../docs/server/protocol.md),
[`spec/wire/protocol.md`](../spec/wire/protocol.md), and
[`spec/protocol/protocol.md`](../spec/protocol/protocol.md) together. The
implementation and executable tests are authoritative when a draft document
does not describe a detail.

## 3. Create a maintainable package

Keep the adapter in its own repository or in `adapters/<community>` while it is
being developed. A useful layout is:

```text
rubydb-example/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── package-or-project-manifest
├── src/
│   ├── connection
│   ├── protocol
│   ├── errors
│   ├── types
│   └── pool
├── tests/
│   ├── unit/
│   ├── protocol/
│   ├── integration/
│   └── security/
└── examples/
    └── basic_app/
```

Keep public API types separate from socket and JSON code. This makes it
possible to replace the transport or add a framework integration without
making application code depend on internal protocol objects.

Use a package name that is valid for the target registry and clearly belongs
to your maintainers. For npm, new package names must be lowercase; a scoped
package therefore looks like `@your-scope/rubydb`, not `@YourScope/rubydb`.
See npm's [package naming guidance](https://docs.npmjs.com/creating-a-package-json-file)
before reserving a name. Never use `rubydb` alone for an unofficial package.

## 4. Implement the protocol boundary

RubyDB uses bounded, newline-delimited JSON messages for its client/server
transport. Each message has an envelope with a `type`, an identifier, a
creation timestamp, and a payload. Keep the following invariants in the driver:

1. Parse the RubyDB URL and reject unknown schemes. Support `rubydb://` for a
   trusted private network and `rubydbs://` for TLS.
2. Open one TCP or TLS connection and enable peer verification by default for
   production TLS connections. Allow CA, client certificate, and key settings
   through configuration or a secret manager, never through committed files.
3. Apply a maximum frame size before allocating unbounded memory. Reject an
   oversized request or response and close the connection safely.
4. Send a handshake with the protocol version, client name, client version,
   username, and database. Follow it with authentication and synchronization.
   Fail closed when the server rejects any step.
5. Give every request a unique ID and correlate responses by ID. Do not assume
   that response order will remain safe if multiplexing or asynchronous
   notifications are added later.
6. Implement the supported operations: `query`, `prepare`, `execute`, `close`,
   `begin`, `commit`, `rollback`, `ping`, and `terminate`.
7. Keep parameter values separate from SQL. Encode supported scalar, array,
   object, date/time, and binary values according to the adapter's documented
   mapping. Never interpolate user input into a query string.
8. Normalize result fields into the community's idioms while preserving column
   metadata, rows, row count, affected rows, and insert identifiers.
9. Map server error codes into stable public exception types. Include a safe
   message and code, but do not expose passwords, TLS keys, or raw secrets in
   logs.

A driver request should conceptually look like this; use the target language's
JSON and socket APIs rather than copying this pseudocode literally:

```text
request_id = new_unique_id()
send {
  type: "query",
  id: request_id,
  created_at: now_as_iso8601,
  payload: {
    sql: "SELECT id, name FROM users WHERE active = ?",
    params: [true],
    deadline_at: deadline_as_iso8601
  }
}
response = read_and_match_id(request_id)
return normalize_result(response.payload.result || response.payload.data)
```

The exact wire behavior belongs in protocol tests, not in assumptions hidden in
the adapter. If you need a protocol capability that RubyDB does not advertise,
open a design issue before inventing a private message type.

## 5. Make transaction behavior explicit

Expose explicit `begin`, `commit`, and `rollback` operations. If your
community API has implicit transactions, document exactly when they begin and
how a connection returns to an idle state.

```text
connection.begin()
try:
    connection.execute(
        "INSERT INTO events (name) VALUES (?)",
        ["community-adapter.started"]
    )
    connection.commit()
except:
    connection.rollback()
    raise
```

A connection must not be returned to a pool while it has an open transaction,
an active cursor, or an unclosed prepared statement. On network loss, mark the
connection unusable and roll back locally; do not silently reuse it.

## 6. Implement deadlines and cancellation safely

Every potentially long operation needs a bounded timeout. On timeout, send a
wire `cancel` request containing the timed-out request's ID, then drain or
close the connection according to the response. Cancellation is cooperative;
it is not permission to kill a thread while it owns database state.

Never automatically retry a write just because the client timed out. The write
may have committed before the response was lost. Tell users to use an
idempotency key or application-level deduplication for retryable writes.

Test all of these cases:

- timeout before the server starts execution;
- cancellation during a long-running query;
- a cancellation response for an unknown request;
- connection loss while cancellation is being sent; and
- a late response arriving after the caller has timed out.

## 7. Add pooling without hiding failures

Provide a bounded pool only if the target community expects one. The pool must
have a maximum size, acquisition timeout, idle cleanup, connection validation,
and deterministic shutdown. A checkout/return API should make ownership clear:

```text
pool = Pool(url, min_size=1, max_size=8)
try:
    rows = pool.use(lambda db:
        db.query("SELECT id FROM jobs WHERE state = ?", ["ready"]).rows
    )
finally:
    pool.close()
```

Do not create one unbounded connection per request. Do not share one connection
between concurrent operations unless the API and protocol explicitly support
that behavior. Pool limits should be lower than the server's connection and
resource limits, with headroom for health checks and migrations.

## 8. Test the adapter against a real server

A protocol fixture is useful for fast unit tests, but it cannot prove that the
adapter works. Add a live integration job that starts a pinned RubyDB server
and runs the adapter against a temporary database.

Minimum test groups:

- URL parsing, defaults, TLS options, type conversion, and public errors;
- fragmented frames, multiple frames, blank lines, malformed JSON, and
  oversized frames;
- handshake, authentication failure, authorization failure, ping, and close;
- parameterized CRUD, `NULL`, booleans, numbers, dates, text, arrays, and JSON;
- prepared statements and statement cleanup;
- commit, rollback, transaction isolation expectations, and pool reuse;
- deadline, wire cancellation, late responses, and connection loss;
- concurrent operations up to the documented pool limit;
- server restart, backup/restore validation, and version mismatch behavior; and
- secrets absent from exceptions, logs, test output, and published artifacts.

Run the RubyDB repository checks first:

```powershell
bundle install
bundle exec rspec
```

Then run the adapter's fast and live suites. The exact commands depend on the
language, but the live suite should receive a URL from the environment rather
than hard-code credentials:

```powershell
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb"
your-package-test-command
your-package-live-integration-command
```

Repeat the live suite over `rubydbs://` with a test CA. Add property or fuzz
tests for the frame decoder and parameter encoder. A driver that passes only a
mock server test is not ready for a community release.

## 9. Document production usage

Your README should include copy-and-paste examples for:

1. local development with an isolated database;
2. starting RubyDB server mode;
3. setting `RUBYDB_URL` through the platform's secret store;
4. TLS with peer verification and certificate rotation;
5. pool sizing and request timeouts;
6. migrations and backup/restore procedures;
7. health checks and metrics; and
8. unsupported SQL, RubyDB versions, operating systems, and framework versions.

Show users the production shape:

```text
Application processes ──TLS/private network──> RubyDB server
       secrets from manager                    durable storage + backups
```

The adapter is not the database server, a backup system, or a failover
controller. Link to RubyDB's [production operations guide](../docs/operations/production-guide.md)
and require users to validate their own workload before making availability or
durability claims.

## 10. Release and maintain the community package

Before the first release:

- choose a license and add a changelog;
- publish a support matrix and compatibility policy;
- enable CI on every supported language/runtime version;
- run unit, live, security, fuzz, and package-content checks;
- verify the package contains no `.env`, credentials, private keys, databases,
  build caches, or test secrets;
- use trusted publishing or a short-lived registry token in CI;
- sign releases when the target registry supports signing;
- tag the source commit and record the RubyDB protocol/server version; and
- provide a security contact and a responsible disclosure policy.

For an npm package, inspect the tarball before publishing:

```sh
npm test
npm pack --dry-run
npm publish --access public
```

For Python, Ruby, Rust, or another registry, use that ecosystem's equivalent
build, metadata, signature, and upload checks. Release the adapter separately
from RubyDB and pin compatible versions in the package metadata. After release,
install the package in a clean environment and rerun the live smoke test.

## Community contribution checklist

Open a pull request or design issue with:

```text
[ ] Adapter name, owner, license, and supported versions are listed.
[ ] Server-mode boundary and embedded-mode limitation are documented.
[ ] Parameter binding is used for every user value.
[ ] Frame limits, malformed input, TLS verification, and secret handling exist.
[ ] Transactions, timeouts, cancellation, and connection cleanup are tested.
[ ] Live tests pass against a pinned RubyDB server.
[ ] Package contents and release provenance are checked.
[ ] README includes installation, examples, operations, and limitations.
```

The adapter becomes part of the wider RubyDB ecosystem when users can install
it, understand its limits, run a real query, observe failures, and upgrade it
without guessing. That standard protects both RubyDB users and the community
maintainer.
