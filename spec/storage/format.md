# Storage format test notes

The storage format uses versioned fixed-size pages with validated headers and
checksums. Tests verify reopen, malformed metadata/page rejection, WAL recovery,
corruption handling, and page-size/version guards.

Do not edit database files by hand in production. Format changes require an
explicit compatibility strategy, upgrade test, backup/restore path, and a
rollback procedure.

## Copy/paste storage safety run

```sh
bundle exec rspec spec/storage_variable_length_persistence_spec.rb spec/crash_recovery_spec.rb spec/engine_recovery_safety_spec.rb
```
