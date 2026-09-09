# SQL transactions

RubyDB supports `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `ROLLBACK TO
SAVEPOINT`, and `RELEASE SAVEPOINT`. Commits coordinate MVCC, locks, row
mutation, WAL, and durable acknowledgement.

Keep transactions short enough for the workload. Long-running readers can
retain old versions and delay vacuum; deadlock victims must retry the
application unit. Validate transaction behavior after restart and under
concurrency.
