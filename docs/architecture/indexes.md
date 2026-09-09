# Indexes

RubyDB provides B-tree indexes for supported table columns, including unique
indexes. The executor can use indexes for eligible lookups while preserving
correctness through table visibility and transaction rules.

Index metadata is persisted with the catalog. Index creation, DML maintenance,
rollback, deep splits, reopen, and failure handling must remain consistent. If
index recovery fails, startup must fail visibly; never silently rebuild or claim
an index is healthy without verification.
