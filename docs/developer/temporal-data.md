# Temporal data

MVCC keeps row versions long enough for active transaction visibility and safe
vacuum. Readers observe a transaction-consistent view according to the selected
isolation behavior; uncommitted changes are not published to other readers.

Long-running transactions retain old versions and can increase storage. Monitor
transaction age and vacuum/compaction duration, and terminate or redesign stale
work before it affects the workload. Test temporal behavior with restart and
rollback, not only a single read.
