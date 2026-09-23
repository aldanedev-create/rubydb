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

## Copy-and-paste compatible CRUD

```sql
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  done BOOLEAN NOT NULL DEFAULT false
);
INSERT INTO tasks (title) VALUES ('Ship the release');
INSERT INTO tasks (title, done) VALUES ('Write restore drill', true);
SELECT id, title FROM tasks WHERE done = false ORDER BY id LIMIT 50;
```

This is a portable starting point for a new application, not proof that an
existing SQLite application will run unchanged. Run its migrations and query
suite against RubyDB before migration.
