# Recovery architecture

Recovery validates the database format, page headers, checksums, metadata, and
WAL before making state available. Valid committed WAL records may be replayed;
malformed or ambiguous records fail closed and require operator investigation.

Recovery procedures work from a preserved source or verified backup. Restore to
a new directory, run dry-run and checksum checks, reopen the restored engine,
compare schema/row evidence, and only then switch application traffic. See the
[disaster recovery](../operations/disaster-recovery.md) procedure.

## Failure handling

Recovery is allowed to replay only validated, committed records. Truncated
frames, invalid checksums, impossible LSNs, and incomplete metadata must stop
startup with an actionable error. Preserve the original directory and WAL;
repair or compaction experiments belong on a copy. The [debugging playbook](../debugging.md)
lists the evidence to collect.
