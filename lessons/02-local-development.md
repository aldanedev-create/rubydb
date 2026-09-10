# Lesson 2: repeatable local development

The fastest safe workflow is to make local setup disposable and repeatable.
Keep database files under `tmp/` or another ignored directory, use separate
development and test paths, and run migrations from source control.

## Rails application setup

Add the RubyDB gems to a Rails application. Pin versions in a real application
after testing them; the versions below match the published example used by the
RubyDB project at the time this lesson was written.

```ruby
# Gemfile
gem "rubydb", "0.1.5"
gem "rubydb-activerecord", "0.1.2"
gem "pg" # Keep this when production may use PostgreSQL.
```

Install dependencies:

```sh
bundle install
```

Configure development and test with separate embedded files:

```yaml
# config/database.yml
default: &default
  adapter: rubydb
  embedded: true
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>

development:
  <<: *default
  database: <%= Rails.root.join("tmp/rubydb_development.rdb") %>

test:
  <<: *default
  database: <%= Rails.root.join("tmp/rubydb_test.rdb") %>
```

Run the schema and tests:

```sh
bin/rails db:create
bin/rails db:migrate
bin/rails test
bin/rails server
```

`db:create` is harmless only when it targets a disposable local path. Never
point it at a production database and never commit `.rdb` files.

## A regular Ruby smoke program

This is a complete single-process example using the public storage API:

```ruby
# script/rubydb_smoke.rb
require "rubydb"

path = "tmp/rubydb_smoke.rdb"
engine = RubyDB::Storage::Engine.new(path)
begin
  engine.execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
  engine.execute("INSERT INTO events (name) VALUES ('boot')")
  rows = engine.execute("SELECT id, name FROM events ORDER BY id")
  puts rows.inspect
ensure
  engine.close
end
```

Run it with:

```sh
bundle exec ruby script/rubydb_smoke.rb
```

For a multi-process application, replace the embedded engine with a RubyDB
server and `RubyDB::Client::Client`. Do not let a web process and a worker
open the same embedded path independently.

## Local PostgreSQL when it is the production target

Use the same application code against a local PostgreSQL instance when you
intend to deploy PostgreSQL. This catches dialect, type, index, and migration
differences early:

```sh
docker run --name rubydb-lesson-postgres \
  --env POSTGRES_PASSWORD=devpassword \
  --env POSTGRES_DB=lesson_app \
  --publish 5432:5432 \
  --detach postgres:16
```

Set the local connection string in your shell or an ignored `.env` file:

```sh
DATABASE_URL=postgresql://postgres:devpassword@127.0.0.1:5432/lesson_app
bin/rails db:migrate
bin/rails test
```

Do not put that password in Git. Stop and remove this disposable container
only after confirming it is the lesson container:

```sh
docker stop rubydb-lesson-postgres
docker rm rubydb-lesson-postgres
```

## Checkpoint

The checkpoint passes when a new developer can clone the project, run
`bundle install`, migrate an empty database, run the tests, and reproduce the
smoke query without manually editing a database file. Continue with [lesson 3](03-embedded-rubydb.md)
to understand the limits of embedded mode.
