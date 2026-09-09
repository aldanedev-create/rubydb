# SQL syntax test notes

Syntax tests define accepted statement forms and required rejection behavior.
They cover tokenization, quoted identifiers, parameter markers, DDL, DML,
transactions, joins, subqueries, CTEs, set operations, upserts, and windows.

Parser acceptance alone is not a production guarantee. Pair syntax changes with
planner, executor, persistence, and compatibility tests.
