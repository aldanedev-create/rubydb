# RubyDB CLI cheat sheet

Replace paths and names before running. Put global options before the command.

## Global

```sh
rubydb --help
rubydb --version
rubydb --config config/production.yml --env production --no-color status --json
```

## Database lifecycle

```sh
rubydb init --name app --dir data
rubydb create --database data/app.rdb
rubydb status --json
rubydb doctor --quick --json
rubydb inspect --database data/app.rdb --stats --wal
rubydb drop --database data/app.rdb              # prompts
rubydb drop --database data/app.rdb --force      # destructive
```

## Server

```sh
rubydb --env production start --host 127.0.0.1 --port 7432 \
  --data-dir /var/lib/rubydb/data --log-dir /var/log/rubydb \
  --pid-file /run/rubydb.pid
rubydb stop --pid-file /run/rubydb.pid
rubydb restart --pid-file /run/rubydb.pid
```

## SQL shell

```sh
rubydb shell --database app --table
rubydb shell --database app --json
```

Inside shell: `.help` `.tables` `.table users` `.schema users` `.status`
`.begin` `.commit` `.rollback` `.explain SELECT ...` `.exit`.

## Migrations

```sh
rubydb migrate --database data/app.rdb --path db/migrate --dry-run
rubydb migrate --database data/app.rdb --path db/migrate
rubydb migrate --database data/app.rdb --path db/migrate --down --steps 1
```

## Backups and restore

```sh
rubydb backup --database data/app.rdb --dir backups --type full --compress
rubydb backup --database data/app.rdb --dir backups --type incremental
rubydb backup --database data/app.rdb --dir backups --type differential
rubydb restore --dir backups --latest --dry-run
rubydb restore --dir backups --latest
rubydb restore --dir backups --backup NAME --point-in-time 2026-09-09T12:00:00Z
```

## Snapshots and branches

```sh
rubydb snapshot --database data/app.rdb --dir snapshots --name before-change
rubydb snapshot --database data/app.rdb --dir snapshots --list
rubydb branch --database data/app.rdb --branch-dir branches --list
rubydb branch --database data/app.rdb --branch-dir branches --create feature --from main
rubydb checkout --database data/app.rdb --branch-dir branches feature
rubydb diff --database data/app.rdb --branch-dir branches main feature --summary
rubydb merge --database data/app.rdb --branch-dir branches feature --into main
```

## Maintenance and release checks

```sh
rubydb vacuum --database data/app.rdb --dry-run
rubydb vacuum --database data/app.rdb --full --analyze
ruby scripts/durability_drill
ruby scripts/replication_failover_drill
ruby scripts/replication_network_failover_drill
ruby scripts/release
```

## Safety rules

- Back up and verify before `migrate`, `merge`, `checkout`, `vacuum --full`, or
  any restore.
- Treat `drop --force`, `create --force`, restore `--force`, and process `--force`
  stop as destructive operations.
- Preserve database, WAL, lock, metadata, logs, and configuration together.
- Use one embedded owner; use server/client mode for multiple processes.
- Never put passwords, tokens, private keys, or API keys in commands committed
  to source control or in captured output.
- A successful CLI exit is not a universal production certification; retain the
  workload, restore, failover, CI, and security evidence.
