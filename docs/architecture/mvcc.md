# MVCC support status

RubyDB currently provides safe READ COMMITTED behavior for the storage engine.
Uncommitted row versions are visible to their owning transaction and hidden
from other transactions. Committed versions become visible after the durable
COMMIT WAL record is written. Deleted physical records remain on pages until
vacuum/compaction and are excluded from ordinary scans.

REPEATABLE READ uses persisted historical row versions and transaction
snapshots. SERIALIZABLE uses snapshot validation over tracked row read/write
keys and conservative table predicates. A newer committed version intersecting
the dependency set aborts commit with a serialization failure. Table-level
predicate tracking prevents phantoms at the cost of false-positive conflicts;
exact index-range predicate locking is a future optimization.

The version store is persisted atomically and supports safe-point vacuuming.
Vacuum never removes active versions and retains the newest committed base
version needed by an active reader; older committed history is removable only
when its commit ID precedes the oldest active transaction.
