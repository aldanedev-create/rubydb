# SQL syntax

Statements are parsed by RubyDB's lexer and parser and executed through the
planner. The supported statements include `SELECT`, `INSERT`, `UPDATE`,
`DELETE`, table/index/schema/view DDL, transactions/savepoints, `EXPLAIN`, and
`VACUUM` as listed in [compatibility](compatibility.md).

Use semicolons for multiple statements only where the client path supports
them. Identifiers may be quoted with double quotes or backticks. Unsupported
syntax fails with a parser or execution error; it is never silently ignored.

## Copy-and-paste schema

```sql
CREATE TABLE IF NOT EXISTS customers (
  id INTEGER PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS customers_email_idx ON customers (email);
SELECT id, email FROM customers WHERE active = true ORDER BY id LIMIT 20;
```

Run the SQL in `rubydb shell --database tmp/app.rdb` or through an adapter.
Keep user input out of SQL text; server clients and ActiveRecord provide bound
parameters. The [compatibility contract](compatibility.md) lists the supported dialect.
