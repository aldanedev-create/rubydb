# First query

RubyDB executes the documented SQL subset through its lexer, parser, planner,
and executor:

```ruby
rows = engine.execute("SELECT id, email FROM accounts WHERE id = 1 ORDER BY id LIMIT 10")
puts rows.inspect
```

Use the Rails connection or client binding APIs for external values. Do not
interpolate untrusted input into SQL. See [SQL compatibility](../sql/compatibility.md)
for supported statements and explicit boundaries.
