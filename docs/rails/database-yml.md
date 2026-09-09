# Rails database configuration

Embedded single-owner configuration:

```yaml
development:
  adapter: rubydb
  database: tmp/development.rdb
  embedded: true
```

For multiple web or worker processes, use a managed RubyDB server and configure
the host, port, credentials, timeout, pool size, TLS, and database name through
protected deployment configuration. Do not put passwords, replication tokens,
or private keys in `database.yml` committed to source control.

Match the total Rails pool size to the server connection limit and leave headroom
for migrations, monitoring, and replication. Test the exact configuration with
the Rails matrix before release.

## Production server/client configuration

For a multi-process Rails deployment, keep the server private and put only
non-secret connection settings in source control. This is a complete example;
the `RUBYDB_*` values are supplied by the deployment environment or secret
manager:

```yaml
production:
  adapter: rubydb
  embedded: false
  host: <%= ENV.fetch("RUBYDB_HOST") %>
  port: <%= ENV.fetch("RUBYDB_PORT", "7432") %>
  database: <%= ENV.fetch("RUBYDB_DATABASE", "rubydb") %>
  username: <%= ENV.fetch("RUBYDB_USERNAME") %>
  password: <%= ENV.fetch("RUBYDB_PASSWORD") %>
  timeout: <%= ENV.fetch("RUBYDB_TIMEOUT", "30") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
  ssl:
    enabled: <%= ENV.fetch("RUBYDB_SSL_ENABLED", "true") == "true" %>
    ca_file: <%= ENV.fetch("RUBYDB_SSL_CA_FILE") %>
    verify_peer: <%= ENV.fetch("RUBYDB_SSL_VERIFY_PEER", "true") == "true" %>
```

Deploy the application with values similar to:

```sh
RUBYDB_HOST=db.internal.example
RUBYDB_PORT=7432
RUBYDB_DATABASE=app
RUBYDB_USERNAME=app_rw
RUBYDB_PASSWORD='provided-by-secret-manager'
RUBYDB_SSL_ENABLED=true
RUBYDB_SSL_CA_FILE=/etc/rubydb/tls/ca.crt
RUBYDB_SSL_VERIFY_PEER=true
```

The exact variable names are application conventions; Rails reads them because
`database.yml` maps them into adapter settings. Do not put the password in a
committed YAML file, Docker image, URL, shell history, or log. The server must
be configured separately with its own data directory, authentication, TLS
certificate/key, and resource limits; see [server configuration](../server/configuration.md).

The current adapter uses discrete `host`/`port`/credential/TLS settings. It
does not promise a single `DATABASE_URL` parser or PostgreSQL wire protocol.
Use the documented mapping above and run a real migration plus smoke query
through the network path before production.
