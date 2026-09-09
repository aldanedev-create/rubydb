# RubyDB Sequel adapter

The Sequel adapter is an integration surface for applications that use Sequel.
It should be configured with a RubyDB connection and kept within the SQL and
schema features documented by RubyDB. Use one embedded owner or point all
processes at a RubyDB server; never open the same embedded path independently
from multiple workers.

Before production use, run the application's Sequel schema, query, transaction,
pool, migration, backup, restore, and failure tests. Compatibility is feature-
specific and is not a claim of complete PostgreSQL, MySQL, or SQLite behavior.
