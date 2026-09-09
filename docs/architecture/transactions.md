# Transactions

Transactions group mutations into a commit or rollback boundary. WAL commit and
flush ordering precede durable acknowledgement. MVCC determines visibility,
while lock management protects conflicting writes and resolves wait-for cycles.

Supported controls include `BEGIN`, `COMMIT`, `ROLLBACK`, savepoints, and
rollback to savepoint. A deadlock victim is rolled back and must retry the whole
application unit as appropriate. Test isolation and recovery together; a green
single-thread transaction test does not prove concurrent correctness.
