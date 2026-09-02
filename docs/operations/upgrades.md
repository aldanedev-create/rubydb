# Upgrades

RubyDB upgrades must be treated as storage migrations, not as an in-place binary replacement.

Before upgrading:

1. Stop writes and confirm the server is healthy.
2. Create and verify a full backup, including WAL when available.
3. Record the RubyDB version, storage page size, and backup manifest checksum.
4. Test the new release against a restored copy of the backup.

The current storage format is version 1. RubyDB refuses to open an unknown page format or a database whose page size differs from the configured page size. There is no automatic on-disk format conversion yet; a future incompatible format must provide an explicit export/import migration.

After upgrading, reopen the restored or migrated database, run the migration status command, verify application queries, and retain the pre-upgrade backup until the rollback window closes. Never delete the original data directory as part of an upgrade.
