# Lesson 8: migrations, backups, and recovery

Production data work is a controlled change to a recoverable system. A green
migration on an empty database is not enough. Test populated tables, rollback
boundaries, disk growth, indexes, locks, and application compatibility.

## RubyDB migration workflow

Preview and apply a migration against a disposable or staging copy:

```sh
rubydb doctor --quick --json
rubydb backup --database data/app.rdb --dir backups --type full --compress
rubydb migrate --database data/app.rdb --path db/migrate --dry-run
rubydb migrate --database data/app.rdb --path db/migrate
```

Run the migration once from a release job, not once per web process. Keep the
pre-migration backup and record the database version, application revision,
backup checksum, operator, and start/end times.

## Verified RubyDB backup and restore

Create a full backup with verification enabled, then dry-run the restore:

```sh
rubydb backup --database data/app.rdb --dir backups --type full --compress
rubydb restore --dir backups --latest --dry-run
rubydb restore --database restored/app.rdb --dir backups --latest
```

If a release depends on incremental or differential backups, retain the entire
required chain and its manifest. Keep backups away from the database disk and
test that a new host can read them. Restore into a new inactive path; do not
overwrite the only source with `--force`.

After restoring, verify both structure and meaning:

```sh
rubydb inspect --database restored/app.rdb --stats --wal
rubydb shell --database restored/app.rdb --json
```

Run schema checks, row counts, foreign-key checks, representative application
queries, and business totals. Record the achieved RPO and RTO rather than
assuming the command’s success proves recoverability.

## PostgreSQL backup and restore

For PostgreSQL, use the provider’s managed backup/PITR feature where possible
and rehearse an independent logical backup:

```sh
pg_dump --format=custom --file=tmp/app-staging.dump "$DATABASE_URL"
createdb app_restore
pg_restore --clean --if-exists --dbname=app_restore tmp/app-staging.dump
```

The restore target must be isolated from production. Validate extensions,
roles, ownership, sequences, indexes, and application behavior after restore.
For a managed service, follow its documented restore and point-in-time
procedure instead of assuming local `createdb` access exists.

## Corruption and interrupted writes

When storage or recovery is suspect:

1. stop application writes and preserve the database, WAL, metadata, config,
   and logs together;
2. copy the evidence to a separate incident location;
3. run `doctor --quick` and `inspect --stats --wal` on the copy;
4. restore the latest verified backup into a new path;
5. compare schema, row counts, checksums, and business totals; and
6. document what data was lost, replayed, or manually reconciled.

Do not “repair” corruption by deleting files, dropping tables, or running full
vacuum on the only copy. Use the repository’s durability and recovery drills
to rehearse interrupted checkpoints, full disks, corrupted files, compaction,
and restore at scale before an incident.

## Checkpoint

The checkpoint passes when an operator who did not create the backup can restore
it on another path, prove the data is usable, and state measured RPO/RTO. Keep
the report with the release evidence. Continue to [lesson 9](09-observability-security-scale.md)
for operations and security.
