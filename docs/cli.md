# RubyDB CLI guide

The `rubydb` command manages local databases, server processes, migrations,
backups, snapshots, branches, inspection, maintenance, and health checks. Run
`rubydb --help` or `rubydb <command> --help` for the installed command's live
options.

## Command shape

```text
rubydb [global options] <command> [command options]
```

Global options must appear before the command:

```sh
rubydb --version
rubydb --no-color --env production status --json
rubydb --config config/production.yml --env production doctor --json
```

Global options are `--config FILE`, `--env ENV`, `--verbose`, `--quiet`,
`--no-color`, `--help`, and `--version`. Commands return zero on success and a
non-zero status on failure. Keep `RUBYDB_DEBUG=1` available when a failed
command needs a Ruby backtrace; never include secrets in captured logs.

## Initialize or create a database

`init` creates a named database under a data directory and installs the default
RubyDB metadata/users/sessions tables:

```sh
rubydb init --name app --dir data
```

`create` creates an empty database file:

```sh
rubydb create --name app --dir data
rubydb create --database /var/lib/rubydb/app.rdb
```

`--force` is destructive for an existing database. Use it only for a disposable
development directory after verifying the path. It is not a production reset
procedure.

## Start, stop, restart, and status

Start a foreground server for development or a service manager:

```sh
rubydb --env production start \
  --host 127.0.0.1 \
  --port 7432 \
  --data-dir /var/lib/rubydb/data \
  --log-dir /var/log/rubydb \
  --pid-file /run/rubydb.pid
```

Use `--daemon` only when an external service manager is not supervising the
process. Prefer systemd, a container supervisor, or an equivalent process
manager for production. Stop gracefully first:

```sh
rubydb stop --pid-file /run/rubydb.pid
rubydb restart --pid-file /run/rubydb.pid
```

`--force` sends a hard termination and can interrupt active work; reserve it
for a confirmed hung process after preserving logs and checking recovery needs.

Inspect local status:

```sh
rubydb --env production status
rubydb --env production status --json > status.json
```

Use JSON status in monitoring, but combine it with the server readiness endpoint,
Prometheus metrics, process state, disk-space checks, and application probes.

## Doctor and inspect

`doctor` runs health/integrity checks. Start with a read-only quick check:

```sh
rubydb doctor --quick --json
rubydb doctor --json > doctor.json
```

`doctor --fix` may perform supported repairs. Take and verify a backup first,
stop application writes, record the output, and review every proposed action:

```sh
rubydb doctor --fix
```

`inspect` reports storage internals without replacing a backup or integrity
verification:

```sh
rubydb inspect --database data/app.rdb --stats --wal
rubydb inspect --database data/app.rdb --pages --indexes
rubydb inspect --database data/app.rdb --table users
```

Use `inspect --wal` to correlate WAL growth with checkpoint/backup incidents.
Do not edit files based on an inspection result; use the documented recovery
procedure.

## SQL shell

Open the configured local database shell:

```sh
rubydb shell --database app
```

Output modes include `--table`, `--json`, and `--csv`. The shell supports these
dot-commands:

| Command | Purpose |
| --- | --- |
| `.help`, `.?` | Show shell help |
| `.exit`, `.quit` | Exit safely |
| `.status` | Show connection/database status |
| `.tables` | List tables |
| `.table NAME` | Describe columns and constraints |
| `.schema NAME` | Show a table definition |
| `.db NAME` | Switch configured local database |
| `.begin`, `.txn` | Begin a transaction |
| `.commit` | Commit the active transaction |
| `.rollback` | Roll back the active transaction |
| `.explain SQL` | Show the selected query plan |
| `.clear`, `.cls` | Clear the terminal |

Example:

```text
users> .tables
users> SELECT id, email FROM users ORDER BY id LIMIT 20;
users> .begin
users> UPDATE users SET active = TRUE WHERE id = 1;
users> .rollback
users> .exit
```

Use bound parameters from application/client APIs for untrusted values. The
shell is an administrative tool, not a connection-pool substitute. For
multiple application processes, use the managed server and client libraries;
never open one embedded path concurrently from independent processes.

## Migrations

Run migrations from the default `db/migrate` directory:

```sh
rubydb migrate --database data/app.rdb --path db/migrate
rubydb migrate --database data/app.rdb --path db/migrate --dry-run
```

To roll back, specify the number of steps and use a verified backup boundary:

```sh
rubydb migrate --database data/app.rdb --path db/migrate --down --steps 1
```

`--version VERSION` targets a migration version. Before applying migrations in
production, stop or coordinate writes, create a verified backup, test against a
populated restore, run schema dump/load and application smoke queries, and keep
the pre-migration directory until rollback closes. Applied migration checksum
changes fail closed.

## Backups and restore

Create a verified full backup:

```sh
rubydb backup --database data/app.rdb --dir backups --type full --compress
```

The supported types are `full`, `incremental`, and `differential`. Use
`--no-verify` only for controlled diagnostics; a release or production backup
should verify. Retain the manifest, checksum, database version, and required
WAL chain together.

List or dry-run a restore before changing a live path:

```sh
rubydb restore --dir backups --latest --dry-run
rubydb restore --database data/app.rdb --dir backups --backup BACKUP_NAME --dry-run
```

Restore to a new inactive directory whenever possible. `--force` is destructive
and must not overwrite the only source. After restore, reopen the engine, verify
schema and row evidence, run application smoke queries, and record RPO/RTO.
Point-in-time restore uses `--point-in-time TIME` only when the required WAL
chain is present and verified.

## Snapshots

Snapshots are useful for staging, inspection, and branch workflows:

```sh
rubydb snapshot --database data/app.rdb --dir snapshots --name before-migration
rubydb snapshot --database data/app.rdb --dir snapshots --list
rubydb snapshot --database data/app.rdb --dir snapshots --restore before-migration
rubydb snapshot --database data/app.rdb --dir snapshots --delete old-snapshot
```

Keep snapshot metadata/checksums and do not treat snapshots as the only backup.
Restore into a separate destination before routing traffic.

## Branches and database diff

List or create a branch:

```sh
rubydb branch --database data/app.rdb --branch-dir branches --list
rubydb branch --database data/app.rdb --branch-dir branches --create feature-x --from main
rubydb checkout --database data/app.rdb --branch-dir branches feature-x
rubydb checkout --database data/app.rdb --branch-dir branches --create experiment
```

Review changes before merging:

```sh
rubydb diff --database data/app.rdb --branch-dir branches main feature-x
rubydb diff --database data/app.rdb --branch-dir branches --summary main feature-x
rubydb diff --database data/app.rdb --branch-dir branches --table users main feature-x
rubydb merge --database data/app.rdb --branch-dir branches feature-x --into main
```

`merge` supports the configured strategy and `--no-commit`. Take a verified
backup, review the diff, test the target with representative data, and preserve
the pre-merge state. Branches are not replication or backup replacements.

## Vacuum and maintenance

Preview maintenance first:

```sh
rubydb vacuum --database data/app.rdb --dry-run
rubydb vacuum --database data/app.rdb --table users
rubydb vacuum --database data/app.rdb --full --analyze
```

Run full vacuum only during an approved maintenance window. Long-running
transactions may retain versions and prevent space reclamation. Monitor free
space, WAL/checkpoint behavior, query latency, and active transaction age.

## Production command sequences

### Pre-deployment

```sh
rubydb --config config/production.yml --env production doctor --quick --json
rubydb --config config/production.yml --env production status --json
rubydb backup --database /var/lib/rubydb/app.rdb --dir /var/backups/rubydb --type full --compress
rubydb migrate --database /var/lib/rubydb/app.rdb --path db/migrate --dry-run
```

### Incident preservation

Stop writes, preserve the database/WAL/log/configuration set, copy it to an
incident directory, and then use `doctor --quick`, `inspect --stats --wal`, and
the restore procedure. Do not use `drop --force`, `create --force`, or vacuum as
an attempted corruption repair.

### Release evidence

Archive command output with the RubyDB commit/version, Ruby version, OS,
database path class, workload, backup name/checksum, restore time, and operator.
The CLI is one part of the production evidence; CI, workload, failover, and
security review records are also required.
