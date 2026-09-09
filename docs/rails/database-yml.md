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
