# SQLite compatibility profile

RubyDB now maintains an explicit SQLite-style compatibility profile for new
Ruby and Rails applications. The profile is tested by
`spec/sqlite_compatibility_spec.rb` and covers the common application surface:

- `CREATE TABLE IF NOT EXISTS`, integer primary keys with `AUTOINCREMENT`,
  defaults, `NOT NULL`, and `UNIQUE`
- CRUD, parameter binding through the Rails connection, transactions, and
  rollback
- `WHERE`, `IS NULL`/boolean predicates, ordering, `LIMIT`/`OFFSET`, joins,
  grouped aggregates, and `HAVING`
- targeted `ON CONFLICT ... DO UPDATE` upserts
- ActiveRecord schema inspection through the embedded adapter

This is useful for applications written against the documented RubyDB surface,
but it is not a complete replacement for the SQLite library. SQLite pragmas,
virtual tables, FTS, recursive query edge cases, extension APIs, file-format
compatibility, and every SQLite function/error behavior remain unsupported or
unverified. An existing SQLite application must run its own migration and
query suite before migration.
