# SQL functions

The tested function surface includes `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`,
`LOWER`, `UPPER`, `LENGTH`, `SUBSTR`, `CONCAT`, `COALESCE`, and `NULLIF`, plus
the documented window ranking and aggregate functions.

Function null behavior and return types are part of the compatibility contract.
Do not assume a PostgreSQL, MySQL, or SQLite extension exists because a function
has the same name; unsupported functions must be reported explicitly.

## Copy-and-paste daily revenue report

```sql
SELECT customer_email,
       COUNT(*) AS order_count,
       SUM(total_cents) AS revenue_cents,
       COALESCE(AVG(total_cents), 0) AS average_order_cents
FROM orders
WHERE created_at >= '2026-09-01 00:00:00'
GROUP BY customer_email
HAVING COUNT(*) >= 2
ORDER BY revenue_cents DESC;
```

Check empty input and null values in application tests; aggregate results are
not a substitute for a validated accounting workflow.
