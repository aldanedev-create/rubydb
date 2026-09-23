# SQL operators and predicates

The documented surface includes arithmetic, comparison, boolean `AND`/`OR` and
`NOT`, `IS NULL`/`IS NOT NULL`, `BETWEEN`, `IN`, `EXISTS`, `LIKE`, `ILIKE`, and
three-valued null behavior covered by the SQL tests.

Use bound parameters for user input. Test false, null, empty string, numeric
precision, and mixed-type values explicitly; similar syntax across SQL engines
does not guarantee identical semantics.

## Copy-and-paste product filter

```sql
SELECT id, sku, price_cents
FROM products
WHERE active = true
  AND price_cents BETWEEN 500 AND 2000
  AND sku ILIKE 'coffee%'
  AND discontinued_at IS NULL
ORDER BY price_cents ASC, id ASC;
```

For an HTTP/API value, send the comparison value as a client parameter instead
of string-building SQL; the Ruby client example in the
[cookbook](../real-world-examples.md#2-rubydb-server-for-a-web-service) shows that form.
