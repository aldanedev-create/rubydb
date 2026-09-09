# Server configuration

Run with an explicit database and resource limits:

```sh
rubydb-server --host 127.0.0.1 --port 7432 --database /var/lib/rubydb/app.rdb
```

Production configuration should set host/port, data and log directories, PID
file, max connections, worker and queue limits, request/frame size, read/write
and idle timeouts, authentication, and TLS. Keep configuration outside source
control when it contains secrets.

Validate configuration before startup and monitor readiness, active/rejected
connections, request errors, disk space, WAL/checkpoint state, and recovery-
required acknowledgements.
