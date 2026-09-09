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

Start with the [developer guide](../developer-guide.md). For failures, use a
fresh copy, preserve WAL and metadata, run the narrowest spec first, then the
full suite. The [debugging playbook](../debugging.md) describes safe logging,
thread dumps, protocol isolation, and diagnostic reports.
