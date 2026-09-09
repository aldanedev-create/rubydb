# SQL data types

The documented RubyDB types are `INTEGER`, `BIGINT`, `SMALLINT`, `FLOAT`,
`DECIMAL`, `BOOLEAN`, `TEXT`, `VARCHAR`, `BLOB`, `DATE`, `TIME`, `TIMESTAMP`,
`JSON`, and `UUID`. Type conversion, nullability, defaults, and constraint
behavior are validated through the SQL and Rails suites.

RubyDB does not claim storage or coercion compatibility with every other SQL
engine. Preserve types explicitly in migrations and test application boundary
values, nulls, booleans, timestamps, decimals, JSON, and binary data.
