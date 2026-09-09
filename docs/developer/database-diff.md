# Database diff

Database diff compares schema and supported state between database snapshots or
branches. Use it to review migration impact and branch changes before applying
them. A diff is evidence for review, not an automatic guarantee that every
application query remains compatible.

For production changes, take a verified backup, inspect the diff, apply it to a
staging restore with representative data, run migrations and smoke queries, and
retain the original for rollback.
