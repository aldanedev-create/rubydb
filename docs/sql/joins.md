# SQL joins

RubyDB supports qualified `INNER`, `LEFT [OUTER]`, `RIGHT`, `FULL [OUTER]`, and
`CROSS JOIN` forms with `ON` predicates in the documented dialect. Outer joins
preserve unmatched rows with null-extended columns.

Use explicit table qualification when columns are ambiguous. Validate join
cardinality, null behavior, ordering, grouping, and transaction visibility with
representative data. Join reordering is limited to safe inner-join plans.

## Copy-and-paste order report

```sql
SELECT o.id AS order_id, c.email, o.total_cents
FROM orders AS o
INNER JOIN customers AS c ON c.id = o.customer_id
WHERE o.created_at >= '2026-09-01 00:00:00'
ORDER BY o.id DESC
LIMIT 50;
```

For an outer-join report, qualify the selected columns and check the null case:

```sql
SELECT c.email, o.id AS order_id
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.id
ORDER BY c.email, o.id;
```
