# SQL compatibility guide

This page is a developer reference for evaluating SQL support. The normative
statement list is [SQL compatibility](compatibility.md); the SQLite-style
application profile is [here](sqlite-compatibility.md). RubyDB does not claim
complete PostgreSQL, MySQL, or SQLite dialect compatibility.

## Compatibility has four layers

An SQL feature is production-ready only when all four layers agree:

1. syntax is parsed and rejected with useful errors;
2. binding and type rules are defined, including `NULL`;
3. planner/executor results and transaction semantics are correct; and
4. Ruby, client/server, and ActiveRecord paths behave consistently.

A parser accepting a statement is not sufficient. Test duplicate rows,
ordering, aggregates, joins, constraints, rollback, savepoints, indexes,
timeouts, and recovery for every feature that mutates or reads data.

## Query review checklist

For each query shape, record schema, indexes, bind types, expected rows,
expected ordering, transaction isolation, and error behavior. Test empty,
single-row, duplicate, `NULL`, and large-result cases. Explicitly order results
when the application requires order; relational results are not inherently
ordered.

Review:

* projections and aliases;
* boolean precedence and `NULL` truth tables;
* inner, left, and multi-table joins;
* grouping, aggregate input, and `HAVING`;
* limits and offsets at boundaries;
* conflict/upsert behavior and affected-row counts;
* casts, defaults, and constraint errors; and
* snapshot visibility during concurrent writes.

## Application migration from SQLite

Start with a schema dump and a representative query/migration inventory. Run
the application test suite against RubyDB, not only a few hand-written
queries. Review pragmas, virtual tables, FTS, extensions, custom functions,
file-format assumptions, recursive queries, date/time behavior, collations,
and error handling. These areas are not included merely because the common
profile looks SQLite-like.

Never point RubyDB at an existing SQLite file and expect it to open. Migrate
through an explicit export/import process with checksums, row counts, and
application-level verification.

## SQL change workflow

Add a contract example under `spec/sql`, parser tests, execution tests, failure
tests, and adapter coverage when relevant. Update the compatibility page and
release notes. Add a regression for every bug. If semantics are intentionally
different from another database, document the difference with a migration
recommendation.

## Safe examples

```sql
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  active BOOLEAN DEFAULT TRUE
);

INSERT INTO users (email, active) VALUES (?, ?);

SELECT active, COUNT(*) AS total
FROM users
WHERE email IS NOT NULL
GROUP BY active
HAVING COUNT(*) > 0
ORDER BY active;
```

Use bound parameters from Ruby or ActiveRecord. Do not construct SQL by
concatenating user input.

