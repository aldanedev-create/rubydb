# SQL data types

The documented RubyDB types are `INTEGER`, `BIGINT`, `SMALLINT`, `FLOAT`,
`DECIMAL`, `BOOLEAN`, `TEXT`, `VARCHAR`, `BLOB`, `DATE`, `TIME`, `TIMESTAMP`,
`JSON`, and `UUID`. Type conversion, nullability, defaults, and constraint
behavior are validated through the SQL and Rails suites.

RubyDB does not claim storage or coercion compatibility with every other SQL
engine. Preserve types explicitly in migrations and test application boundary
values, nulls, booleans, timestamps, decimals, JSON, and binary data.

## Copy-and-paste application table

```sql
CREATE TABLE IF NOT EXISTS api_events (
  id UUID PRIMARY KEY,
  account_id BIGINT NOT NULL,
  occurred_at TIMESTAMP NOT NULL,
  successful BOOLEAN NOT NULL,
  amount DECIMAL(12, 2),
  payload JSON,
  attachment BLOB
);
```

Use the type and precision required by the business rule, then test the
application boundary values after every migration. Do not rely on implicit
cross-database coercions.
