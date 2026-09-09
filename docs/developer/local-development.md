# Local development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

Use `tmp/` or `Dir.mktmpdir` for databases. The server/client examples are
appropriate when testing process boundaries. Do not open one embedded path from
multiple processes. Use the reported fuzz seed and commit when reproducing a
failure.
