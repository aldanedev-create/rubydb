# Server deployment

Run RubyDB under a dedicated least-privilege service account with protected
data, WAL, logs, TLS, and backup paths. Use the packaged systemd unit or the
non-root Docker image, private networking, TLS, authentication, resource
limits, health checks, and persistent storage.

Before accepting traffic, run status/readiness, smoke queries, backup/restore,
workload, and recovery checks. Keep one writable primary, fence before
promotion, and retain the previous data directory during upgrades.

## Copy/paste deployment preflight

```sh
rubydb status --json
rubydb doctor --quick --json
ruby scripts/restore_drill
rubydb backup --database /var/lib/rubydb/data/app.rdb --dir /var/lib/rubydb/backups --type full --compress
```
