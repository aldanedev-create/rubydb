# SQL engine

RubyDB implements a documented RubyDB SQL subset with a tested common
SQLite-style application profile. Covered features include CRUD, constraints,
joins, grouping/aggregates, transactions/savepoints, CTEs, subqueries, set
operations, upserts, windows, indexes, views, and maintenance statements listed
in [SQL compatibility](../sql/compatibility.md).

This is not complete PostgreSQL, MySQL, or SQLite dialect/file-format
compatibility. Unsupported syntax must fail explicitly. Applications migrating
from another engine must run their own schema, query, migration, and error
behavior suite.

## Copy/paste SQL smoke test

This common application profile is safe to use as a first compatibility check:

```sh
rubydb shell --database tmp/sql-example.rdb
```

```sql
CREATE TABLE IF NOT EXISTS invoices (id INTEGER PRIMARY KEY, customer TEXT NOT NULL, total_cents INTEGER NOT NULL);
INSERT INTO invoices (id, customer, total_cents) VALUES (1, 'Ada', 4200);
SELECT customer, total_cents FROM invoices WHERE total_cents > 0 ORDER BY id;
```
