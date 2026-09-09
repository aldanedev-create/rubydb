# SQL operators and predicates

The documented surface includes arithmetic, comparison, boolean `AND`/`OR` and
`NOT`, `IS NULL`/`IS NOT NULL`, `BETWEEN`, `IN`, `EXISTS`, `LIKE`, `ILIKE`, and
three-valued null behavior covered by the SQL tests.

Use bound parameters for user input. Test false, null, empty string, numeric
precision, and mixed-type values explicitly; similar syntax across SQL engines
does not guarantee identical semantics.
