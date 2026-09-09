# Storage format test notes

The storage format uses versioned fixed-size pages with validated headers and
checksums. Tests verify reopen, malformed metadata/page rejection, WAL recovery,
corruption handling, and page-size/version guards.

Do not edit database files by hand in production. Format changes require an
explicit compatibility strategy, upgrade test, backup/restore path, and a
rollback procedure.
