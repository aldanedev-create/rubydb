# SQL joins

RubyDB supports qualified `INNER`, `LEFT [OUTER]`, `RIGHT`, `FULL [OUTER]`, and
`CROSS JOIN` forms with `ON` predicates in the documented dialect. Outer joins
preserve unmatched rows with null-extended columns.

Use explicit table qualification when columns are ambiguous. Validate join
cardinality, null behavior, ordering, grouping, and transaction visibility with
representative data. Join reordering is limited to safe inner-join plans.
