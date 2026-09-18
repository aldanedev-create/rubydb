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

## Bundled Go accelerator

The checkout includes the Go accelerator source under `accelerator/`. Go is
needed to build RubyDB, not to run an installed gem. The release gem contains
the platform binary and falls back to Ruby if a platform is not packaged. To
build the binaries from a checkout:

```sh
ruby scripts/build_accelerator
ruby -Ilib exe/rubydb accelerator --ping --json
```

Use Ruby-only mode while diagnosing a query difference:

```sh
RUBYDB_ACCELERATOR=off bundle exec rspec spec/sql_compatibility_spec.rb
```

The default `auto` mode uses the binary columnar protocol, checks result
equivalence against Ruby on the first eligible scan/aggregate/join, and keeps
Go only when it is faster. Use required mode in a controlled integration test
to ensure a deployment has the expected binary:

```yaml
accelerator:
  mode: required
  min_rows: 0
```

The Go worker is private to its Ruby parent. It is not a database server and
does not make an embedded file safe to open from multiple processes.

Start with the [developer guide](../developer-guide.md). For failures, use a
fresh copy, preserve WAL and metadata, run the narrowest spec first, then the
full suite. The [debugging playbook](../debugging.md) describes safe logging,
thread dumps, protocol isolation, and diagnostic reports.
