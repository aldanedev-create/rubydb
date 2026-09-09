# Query planner

The planner binds identifiers to catalog columns, validates expressions, and
builds executable plans. It supports sequential/index scans, safe inner-join
reordering, outer joins, filters, grouping, sorting, limits, set operations,
subqueries, CTEs, and window operations in the documented SQL surface.

Plans must preserve SQL null, ordering, grouping, and transaction visibility
semantics. `EXPLAIN` reports the actual selected plan; it is not a performance
promise. Use the benchmark and workload harnesses to establish capacity on the
target hardware.
