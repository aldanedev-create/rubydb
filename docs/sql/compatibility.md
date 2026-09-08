# RubyDB SQL compatibility

RubyDB supports a deliberately narrow, RubyDB-native SQL dialect. This is not
a claim of PostgreSQL or SQLite compatibility.

Supported and tested statements include:

- `SELECT` with projections, `WHERE`, ordering, limits, offsets, built-in
  expressions, and `COUNT`, `SUM`, `AVG`, `MIN`, and `MAX` aggregates with
  `GROUP BY` and `HAVING`
- `UNION`, `UNION ALL`, `INTERSECT`, and `EXCEPT` for compatible SELECT
  projections
- non-correlated scalar subqueries and `IN (SELECT ...)` predicates
- materialized non-recursive `WITH` common table expressions; recursive CTEs
  are rejected explicitly
- `INSERT`, `UPDATE`, and `DELETE`
- `CREATE TABLE` and `DROP TABLE`, including primary keys, unique constraints,
  checks, foreign keys, and referential actions
- `CREATE INDEX`/`CREATE UNIQUE INDEX` and `DROP INDEX`
- `ALTER TABLE` add/drop columns and constraints
- `CREATE`/`DROP DATABASE`, `CREATE`/`DROP SCHEMA`, and `CREATE`/`DROP VIEW`
- supported trigger metadata DDL: `CREATE TRIGGER ... EXECUTE FUNCTION ...`
- `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `ROLLBACK TO SAVEPOINT`, and
  `RELEASE SAVEPOINT`
- `EXPLAIN`, `EXPLAIN ANALYZE`, and `VACUUM`

Unsupported syntax must fail with a parser or execution error. RubyDB does not
promise arbitrary SQL extensions, PostgreSQL wire-level compatibility, or
feature parity with another database engine. The executable contract is the
integration coverage under `spec/`.
