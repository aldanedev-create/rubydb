# Rails migrations

RubyDB supports the documented ActiveRecord migration surface, including table
creation, integer primary keys, columns, defaults, indexes, constraints, and
populated-table round trips covered by the adapter suite.

Before production migration:

1. verify a full backup and WAL chain;
2. restore into a new staging directory with representative data;
3. run the migration, schema dump/load, application queries, and rollback path;
4. confirm the migration checksum and schema status;
5. retain the pre-migration directory until rollback is no longer needed.

RubyDB fails closed when an applied migration changes or disappears. Unsupported
table rebuilds, generated columns, polymorphic references, and dialect-specific
extensions require explicit validation.
