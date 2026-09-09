# Query planner

The planner binds identifiers to catalog columns, validates expressions, and
builds executable plans. It supports sequential/index scans, safe inner-join
reordering, outer joins, filters, grouping, sorting, limits, set operations,
subqueries, CTEs, and window operations in the documented SQL surface.

Plans must preserve SQL null, ordering, grouping, and transaction visibility
semantics. `EXPLAIN` reports the actual selected plan; it is not a performance
promise. Use the benchmark and workload harnesses to establish capacity on the
target hardware.

## Plan review

For every rewrite, compare the optimized and baseline results on empty,
duplicate, null, and concurrent data. Include joins with unmatched rows,
grouping, limits, and repeated execution with bound parameters. Measure plan
selection, execution, lock wait, and I/O separately. A plan that is faster but
changes cardinality or ordering is incorrect; add the minimized query as a
regression spec before merging.
