# Tiny GitHub clone (Rails + RubyDB)

This is intentionally small. It is a smoke test for RubyDB through the real
ActiveRecord adapter, not a complete GitHub implementation. It supports:

* repositories;
* issues; and
* a tiny commit activity list.

## Run it

From this directory:

```sh
bundle install
bundle exec ruby bin/rails db:migrate
bundle exec ruby bin/rails db:seed
bundle exec ruby bin/rails server -b 127.0.0.1 -p 3002
```

On Windows, the Gemfile pins `irb` and `rdoc` to avoid a native `rbs` build
that is not needed by this example.

Open <http://127.0.0.1:3002/>. The embedded database is created at
`tmp/github_clone.rdb`. Set `RUBYDB_DATABASE` to use another local path. The
`bundle exec ruby bin/rails` form works on both Windows and Unix-like systems.

## What this tests

The app exercises Rails migrations, primary keys, foreign keys, indexes,
validations, associations, ordering, joins, inserts, and a small transaction
through RubyDB. Run the app and create an issue and commit to verify writes.

The migration intentionally uses Rails' `references` shorthand so this example
also checks the adapter's normal foreign-key convention.

This example uses one embedded owner for local testing. For multiple web or
worker processes, set `embedded: false` and use a RubyDB server URL as shown in
the [local-to-production guide](../../docs/getting-started/local-to-production.md).
