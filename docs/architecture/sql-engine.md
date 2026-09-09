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
