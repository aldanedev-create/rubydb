## Restore verification

Before treating a backup as recoverable, run the verification path that extracts
it into an isolated temporary directory, opens the database with RubyDB, and
compares the restored catalog and table row counts with the manifest. The
verification removes its temporary database after the check.
