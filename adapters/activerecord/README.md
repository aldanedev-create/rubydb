# rubydb-activerecord

`rubydb-activerecord` is the ActiveRecord adapter for [RubyDB](https://github.com/aldanedev-create/rubydb). It lets Rails applications use RubyDB through the normal model, relation, transaction, migration, schema, and connection-pool APIs.

This gem is an adapter to RubyDB's SQL engine. It is not a PostgreSQL, MySQL, or SQLite wire-protocol compatibility layer, and it does not make arbitrary dialect-specific SQL portable. Validate your application's queries and migrations against the exact Ruby, Rails, RubyDB, operating-system, and deployment versions you will run.

## Requirements

- Ruby 3.3 or newer
- RubyDB 0.1.x
- ActiveRecord 7.1, 7.2, or 8.0 (the dependency range is `>= 7.1`, `< 8.1`)

## Install

Add both gems to the Rails application's `Gemfile`:

```ruby
gem "rubydb"
gem "rubydb-activerecord"
```

Then run:

```sh
bundle install
```

The adapter registers itself under the `rubydb` adapter name when it is
required by Bundler. For a manually loaded application, require it explicitly:

```ruby
require "rubydb"
require "active_record/connection_adapters/rubydb_adapter"
```

## Development: embedded database

Embedded mode is convenient for local development and a controlled
single-process application. The process owns the database file:

```yaml
# config/database.yml
development:
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/development.rdb") %>
```

Run migrations normally:

```sh
bin/rails db:migrate
bin/rails console
bin/rails server
```

Do not open the same embedded path from multiple independent Rails processes.
For multiple web workers, job workers, or hosts, use a managed RubyDB server.

## Production: managed server

Use a network connection when the application has more than one process or
when the database must be operated independently from the application. Keep
credentials in the platform secret manager and map them into `database.yml`:

```yaml
# config/database.yml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
  timeout: <%= ENV.fetch("RUBYDB_TIMEOUT", "30") %>
```

Use `rubydb://` for a plain private-network connection or `rubydbs://` for TLS:

```text
rubydbs://app_user:URL_ENCODED_PASSWORD@db.internal.example:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

The server must be deployed separately with persistent storage,
authentication, TLS, backups, monitoring, resource limits, and a tested
restore procedure. Size its connection limit for the total Rails pool across
all application processes, with headroom for administration and replication.
See the repository's [Rails database configuration](../../docs/rails/database-yml.md)
and [production guidance](../../docs/rails/production.md).

## Adapter surface

The release test suite exercises:

- ActiveRecord CRUD, binds, quoted identifiers, type casting, and false/zero values
- transactions and savepoints
- `joins`, qualified filters, ordering, eager loading, and nested associations
- table/column/index/foreign-key introspection
- Rails migrations, defaults, indexes, schema dumps, and populated-table changes
- embedded and network connection setup paths

RubyDB currently has documented SQL and schema boundaries. Features outside
the tested surface—such as dialect-specific extensions, generated columns,
complex table rebuilds, or application-specific Arel—need explicit tests
before deployment.

## Validation

Run the adapter's integration suite from this directory:

```sh
bundle install
bundle exec rspec spec
```

Run the repository's Rails-focused checks from the repository root:

```sh
bundle exec rspec spec/rails_adapter_live_engine_spec.rb spec/rails_adapter_schema_dump_spec.rb spec/rails_schema_statements_spec.rb
```

Before a production release, run a real migration and smoke query through the
same server URL, TLS settings, pool size, and secret-management path used by
the deployment. Keep a verified backup before migrations and rehearse restore
and rollback on a representative copy.

## Support and release policy

The adapter version is coupled to the RubyDB 0.1.x release line. Pin both gems
in the application lockfile, upgrade them together, and run the adapter suite
before upgrading Rails. Report reproducible adapter or engine issues at the
project's [issue tracker](https://github.com/aldanedev-create/rubydb/issues)
with Ruby/Rails/RubyDB versions, the SQL or migration involved, and a redacted
configuration summary. Never include passwords, connection URLs, database
files, or private keys in reports.
