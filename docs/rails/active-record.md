# ActiveRecord adapter

The `rubydb-activerecord` adapter connects ActiveRecord models to RubyDB. The
tested surface includes CRUD, quoted identifiers, binds, associations, joins,
eager loading, nested associations, schema inspection, transactions, indexes,
defaults, schema dumps, and populated-table migration paths.

Run the adapter suite from `adapters/activerecord` for the target Rails version.
Use server mode when multiple Rails processes share a database. The adapter is
not a complete PostgreSQL, MySQL, or SQLite compatibility layer; validate any
application-specific Arel, extension, callback, migration, or SQL behavior.

## Copy/paste Rails query

```ruby
# Run from a Rails console after the adapter is configured.
orders = Order.where(status: "paid")
               .joins(:customer)
               .includes(:line_items)
               .order(created_at: :desc)
               .limit(20)
puts orders.map(&:id)
```

Run this against a populated staging database on the exact Rails version you
intend to deploy; the adapter is not a universal Arel or SQL dialect layer.
