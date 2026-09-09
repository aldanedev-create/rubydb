# Disaster recovery

Define application-specific recovery objectives before deployment:

- RPO: the maximum acceptable committed data loss.
- RTO: the maximum time to restore service.
- retention: how long backups and incident copies must be kept.

RubyDB’s verified recovery path is restore to a new directory followed by an
engine reopen and row/catalog verification. It does not silently repair
unknown corruption or perform automatic cross-region failover.

## Recovery procedure

1. Declare the incident and stop application writes to the affected database.
2. Preserve the original data directory, WAL, logs, configuration, and process
   information. Work from a copied incident set.
3. Select the newest backup whose manifest and checksum verify within the RPO.
4. Restore into a new directory and run `rubydb restore --dry-run` before
   opening it.
5. Open the restored database, run migrations/status checks, and execute the
   application smoke and integrity queries.
6. Switch the application to the restored directory only after validation.
7. Preserve the failed directory until the incident review is complete.

Run `ruby scripts/restore_drill` in staging on the same filesystem and RubyDB
release family used in production. Record measured restore time, recovered WAL
position, row counts, and any gaps against RTO/RPO.

Do not remove WAL, run vacuum, force promotion, or overwrite the source during
an active corruption investigation.
