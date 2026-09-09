# Execution engine

The execution pipeline is:

`SQL text -> lexer -> parser/AST -> binder -> planner -> executor -> result`

The planner selects scans, index scans, joins, filters, aggregates, sorting,
limits, set operations, CTEs, subqueries, and window operations supported by
the documented dialect. DML is routed through transaction-aware executors and
the engine's durable mutation path.

Unsupported syntax must produce an explicit parser or execution error. New
operators and functions require type-checking, null behavior, transaction
coverage, and compatibility documentation.
