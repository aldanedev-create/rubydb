# Rails troubleshooting

## Connection or ownership errors

Confirm the database path exists, the process has permission, and no second
embedded owner is using it. Multiple Rails processes must use server mode.

## Migration failures

Stop writes, preserve the database and WAL, inspect migration status and
checksums, and retry only after restoring a verified staging copy. Do not delete
WAL or overwrite the original directory.

## Query failures

Capture the RubyDB version, Rails/Ruby versions, generated SQL without secrets,
and a minimal schema/query reproduction. Check the documented SQL and adapter
compatibility surface before changing application behavior.
