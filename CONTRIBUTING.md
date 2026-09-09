# Contributing to RubyDB

RubyDB is a correctness-first database project. Small, reviewable changes with
tests and documentation are preferred over broad changes with unverified
claims.

## Development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

Use a temporary database for tests. Do not commit database files, credentials,
generated private keys, coverage output, or release artifacts. Follow the
architecture and testing guides in `docs/`.

## Pull requests

Explain the invariant being changed, the failure mode it prevents, and the
rollback or compatibility impact. Add regression coverage for parser,
execution, storage, transaction, protocol, adapter, or operational changes.
Run the relevant workload, crash, backup/restore, and security checks. Update
the compatibility contract when behavior changes.

Never describe a simulated fault test as proof of physical power-loss,
multi-host, or independent security-review results. See the
[lessons learned](docs/lessons-learned.md) guide.
