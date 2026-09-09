# Rails quick start

The runnable application under `examples/rails_app` demonstrates a real Rails
migration, model, query, and server:

```sh
cd examples/rails_app
bundle install
bundle exec ruby bin/rails db:migrate
bundle exec ruby bin/rails server -b 127.0.0.1 -p 3001
```

Use the ActiveRecord adapter only within its tested feature surface. For a
production Rails deployment, use server mode for multiple processes, protect
TLS/authentication secrets, back up before migrations, and run the exact Rails
matrix and populated-schema checks described in `docs/rails/production.md`.
