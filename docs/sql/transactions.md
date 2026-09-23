# SQL transactions

RubyDB supports `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `ROLLBACK TO
SAVEPOINT`, and `RELEASE SAVEPOINT`. Commits coordinate MVCC, locks, row
mutation, WAL, and durable acknowledgement.

Keep transactions short enough for the workload. Long-running readers can
retain old versions and delay vacuum; deadlock victims must retry the
application unit. Validate transaction behavior after restart and under
concurrency.

## Copy-and-paste order write

Run this in `rubydb shell --database tmp/orders.rdb` after creating `products`
and `orders`. A failure before `COMMIT` leaves no partial order.

```sql
BEGIN;
UPDATE products SET stock = stock - 1
WHERE id = 42 AND stock > 0;
INSERT INTO orders (id, customer_email, total_cents, created_at)
VALUES (1001, 'ada@example.test', 1899, '2026-09-23 12:00:00');
COMMIT;
```

If any statement fails, issue `ROLLBACK;` and retry the complete business
operation only when it is idempotent. See the [order-service cookbook](../real-world-examples.md).
