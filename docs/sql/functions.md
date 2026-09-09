# SQL functions

The tested function surface includes `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`,
`LOWER`, `UPPER`, `LENGTH`, `SUBSTR`, `CONCAT`, `COALESCE`, and `NULLIF`, plus
the documented window ranking and aggregate functions.

Function null behavior and return types are part of the compatibility contract.
Do not assume a PostgreSQL, MySQL, or SQLite extension exists because a function
has the same name; unsupported functions must be reported explicitly.
