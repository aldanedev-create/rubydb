# RubyDB operator runbook

## Start and health check

Run the server with an explicit production configuration:

```sh
RUBYDB_ENV=production rubydb -c config/production.yml start
```

Confirm the process is listening, then run `rubydb status --json`. Treat a missing PID file, an invalid configuration, or a failed health check as a failed deployment; do not bypass startup validation.

## Backup and restore

Create a verified full backup before upgrades or maintenance. Retain the manifest and WAL chain together. Test restoration into a separate directory before replacing a live data directory. Never restore over an active database.

## Upgrade and rollback

Stop writes, create and verify a full backup, restore it into a staging directory, and run migration status plus application smoke queries. Promote the staged directory only after validation. Roll back by stopping RubyDB and switching back to the retained pre-upgrade directory; preserve the failed directory for diagnosis.

## Incident boundaries

On corruption, checksum failure, repeated crash recovery, or replication divergence, stop writes and preserve the data directory and logs. Do not delete WAL, run vacuum, or force promotion until a verified backup and incident copy exist. Automatic failover is intentionally disabled and promotion requires an operator decision.

## Security operations

Keep production credentials and TLS private keys outside the repository with restrictive permissions. Rotate certificates by staging the replacement, validating the chain, and restarting during a planned window. Keep TLS enabled and use peer verification when a trusted CA is available.
