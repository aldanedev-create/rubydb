# Backup policy

Backups are only useful after they have been verified and restored. Keep the
database file, WAL chain, backup manifest, and checksum together. Store a copy
outside the database host and encrypt it with the organization’s approved
archive tooling.

## Create and verify

Stop writes for a maintenance backup when possible, then run:

```sh
rubydb backup --dir /var/lib/rubydb/backups
rubydb restore --latest --dry-run --dir /var/lib/rubydb/backups
```

The backup implementation flushes the WAL and storage before copying files and
publishes its manifest atomically. A successful command is not a substitute for
the scheduled restore drill in `scripts/restore_drill`.

## Retention and deletion

Use a documented retention schedule such as daily backups for 14 days, weekly
backups for 12 weeks, and monthly backups for the required compliance period.
Delete only verified, expired backup sets; never delete a base backup while an
incremental or differential chain depends on it.

## Recovery point checks

Record the backup name, manifest checksum, database version, page size, WAL
position, and verification result in the deployment record. Before restoring,
confirm that the selected backup is complete and that its destination is a new,
inactive directory.
