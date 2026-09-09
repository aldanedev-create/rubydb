# ActiveRecord adapter

The `rubydb-activerecord` adapter connects ActiveRecord models to RubyDB. The
tested surface includes CRUD, quoted identifiers, binds, associations, joins,
eager loading, nested associations, schema inspection, transactions, indexes,
defaults, schema dumps, and populated-table migration paths.

Run the adapter suite from `adapters/activerecord` for the target Rails version.
Use server mode when multiple Rails processes share a database. The adapter is
not a complete PostgreSQL, MySQL, or SQLite compatibility layer; validate any
application-specific Arel, extension, callback, migration, or SQL behavior.
