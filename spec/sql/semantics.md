# SQL semantic test notes

Semantic tests cover three-valued null behavior, boolean values, ordering,
grouping, aggregates, joins, constraints, conflict handling, transactions, and
visibility. Expected results should be written as observable rows or errors,
not implementation details that could hide a broken durable path.

When adding a SQL feature, include empty input, null input, duplicate input,
transaction rollback, and reopen coverage where applicable.
