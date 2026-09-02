# RubyDB application smoke tests

These are executable applications, not mock examples. They exercise the local
RubyDB source tree and are useful as release smoke tests.

## Regular Ruby

```sh
cd examples/production_smoke/regular_ruby
ruby app.rb
```

The program creates an account, closes the engine, reopens it, and verifies the
row is durable.

## Rails and ActiveRecord

```sh
cd examples/production_smoke/rails_app
bundle install
bundle exec ruby smoke_test.rb
```

The Rails program boots a Rails application, establishes an ActiveRecord RubyDB
connection, creates a schema, persists an `Account`, and reads it back.

For an installed application, replace the local `path:` gems in the Rails
Gemfile with released `rubydb` and `rubydb-activerecord` versions. Embedded
deployments must put the database path on durable storage and close the engine
cleanly during process shutdown.
