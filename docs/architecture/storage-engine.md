# Storage engine

The storage engine owns the database path, page manager, buffer pool, catalog,
indexes, WAL, and recovery lifecycle. It serializes durable changes and exposes
Ruby-native operations used by the SQL executor and adapters.

Embedded ownership is exclusive and enforced with an operating-system lock.
Multiple processes must use the server. On failure, callers should preserve the
original directory and recover into a new destination; do not delete WAL or
overwrite the source during investigation.

Storage changes require reopen, crash, fault-injection, corruption, compaction,
and backup/restore coverage. The [lessons learned](../lessons-learned.md) page
explains why these are separate guarantees.
