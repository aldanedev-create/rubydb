# Indexes

RubyDB provides B-tree indexes for supported table columns, including unique
indexes. The executor can use indexes for eligible lookups while preserving
correctness through table visibility and transaction rules.

Index metadata is persisted with the catalog. Index creation, DML maintenance,
rollback, deep splits, reopen, and failure handling must remain consistent. If
index recovery fails, startup must fail visibly; never silently rebuild or claim
an index is healthy without verification.

## Change checklist

Index changes require coverage for empty and populated tables, duplicate and
null keys, deep splits, deletes, rollback, crash/replay, compaction, and
concurrent readers. Compare an index lookup with a table scan before and after
reopen. A required-index persistence error must abort the owning operation and
be observable by the caller. See [troubleshooting](../troubleshooting.md) for
the safe response to suspected index corruption.
