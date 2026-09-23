# Architecture contribution guide

Before changing a core subsystem, identify its ownership, durability boundary,
failure behavior, and public compatibility contract. Changes to storage, WAL,
recovery, transactions, replication, protocol, or adapters need focused tests
and an end-to-end regression.

Document invariants in the relevant architecture page and add a lesson when a
new failure mode is discovered. Prefer explicit errors over silent fallback.

## Copy/paste contribution check

Before opening a change that crosses a durability boundary, run the focused
spec and the full suite:

```sh
bundle exec rspec spec/transaction_crash_recovery_spec.rb
bundle exec rspec
```
