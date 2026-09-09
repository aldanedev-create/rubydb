# Testing guide

The test layers are complementary:

- unit specs validate isolated algorithms and invariants;
- integration specs run the real parser, planner, executor, storage, server,
  client, adapter, or replication path;
- chaos/fault specs inject write, crash, corruption, and network failures;
- workload scripts measure concurrency, latency, cancellation, capacity, and
  durable reopen behavior;
- CI covers supported Ruby/Rails/OS combinations, security scans, fuzzing, and
  release preflight.

Run `bundle exec rspec` for the complete local gate. Preserve the random seed
when reproducing failures. A passing local suite does not replace hosted
multi-host, physical-filesystem, or independent security validation.
