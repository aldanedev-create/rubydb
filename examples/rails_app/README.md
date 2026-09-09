# Rails + RubyDB example

This is a small Rails 7.2 application using RubyDB through the real
`rubydb-activerecord` adapter. It uses an embedded RubyDB engine, so no
separate database service is needed.

From this directory:

```sh
bundle install
bundle exec ruby bin/rails db:migrate
bundle exec ruby bin/rails server -b 127.0.0.1 -p 3001
```

Open <http://127.0.0.1:3001/> and create a task. The database files are
created under `tmp/` and are ignored by the repository. Set `RUBYDB_DATABASE`
for a different database path. For a separately managed RubyDB server, use
the adapter's network connection settings instead of the embedded initializer.
