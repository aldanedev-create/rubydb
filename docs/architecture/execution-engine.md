# Execution engine

The execution pipeline is:

`SQL text -> lexer -> parser/AST -> binder -> planner -> executor -> result`

The planner selects scans, index scans, joins, filters, aggregates, sorting,
limits, set operations, CTEs, subqueries, and window operations supported by
the documented dialect. DML is routed through transaction-aware executors and
the engine's durable mutation path.

Unsupported syntax must produce an explicit parser or execution error. New
operators and functions require type-checking, null behavior, transaction
coverage, and compatibility documentation.

## Execution invariants

The executor must consume a bound plan, check cancellation and deadlines at
bounded points, and return either a complete result or an error that leaves the
transaction in a documented state. DML goes through the same transaction and
WAL path as the Ruby API; a server response must never bypass durable commit.

When diagnosing a result, compare parser output, bound parameters, selected
plan, row visibility, and final serialization. See the [developer guide](../developer-guide.md)
and [debugging playbook](../debugging.md).

## Copy/paste query check

This exercises the public parser, planner, executor, and storage path with a
real order-style query:

```ruby
require "rubydb"

db = RubyDB.open("tmp/execution-example.rdb")
begin
  db.execute("CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY, status TEXT, total_cents INTEGER)")
  db.insert_many("orders", [
    { id: 1, status: "paid", total_cents: 2500 },
    { id: 2, status: "pending", total_cents: 900 }
  ])
  p db.query("SELECT status, SUM(total_cents) AS revenue FROM orders GROUP BY status ORDER BY revenue DESC")
ensure
  db.close
end
```
