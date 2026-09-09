# Remaining production work

Completed checkpoints: exclusive embedded engine ownership, duplicate-open
rejection, release after process exit, initialization failure cleanup, fail-closed
metadata and recovery startup, atomic metadata replacement, and deterministic
background-maintenance shutdown.

The following work remains open; passing the regression suite does not certify
these capabilities.

1. Server concurrency: cancellation and sustained load with latency percentiles.
   Client deadlines are checked before execution and propagated into the query
   executor, which checks during long read phases. Engine transaction state is
   now scoped per client connection thread, and concurrent commit/rollback
   behavior is covered. Multi-process durability is covered; wire-level
   wire cancellation is now request-scoped and cooperative: a client can send
   a cancel frame while the connection reader remains active, and the server
   acknowledges it only for the active request. Mixed transaction reference-log
   and restart validation remain open.
2. Persistence: fault-test disk-full and interrupted checkpoints/schema changes;
   index metadata load and write errors now fail visibly, and failed schema
   publications roll back in-memory state. Metadata and index catalogs are
   published through unique temporary files with flush/fsync/atomic rename.
   Commit acknowledgements now expose durable versus uncertain WAL state and
   recovery-required post-WAL flush failures. Fault-injection coverage for
   checkpoints and broader page-write failures remains.
3. SQL correctness: ambiguous identifiers, aggregate edge cases (NULLs,
   DISTINCT, and expressions), and schema changes on populated tables remain
   open. Boolean false values, `IS NULL`, NULL comparison behavior, and
   outer-join NULL extension now have regression coverage. Non-recursive CTEs,
   subqueries, set operations, targeted `ON CONFLICT DO UPDATE`, and
   ranking/partition window functions, explicit `ROWS` window frames, bounded
   recursive CTEs, dependency-aware inner-join reordering, and targetless
   conflict updates using primary/unique definitions are implemented; multi-row
   `VALUES` sources are now atomic when executed outside a caller transaction.
   Broader dialect upsert forms and statistics-driven plan costing remain open.
4. Replication: synchronized acknowledgements and promotion with an explicit
   recovery point. Engine commits now package all committed row changes into a
   single replication envelope after the local WAL commit point. Primary
   connections bootstrap the catalog before row replay, including empty replicas. TCP input now
   uses bounded newline framing and replay positions are fsynced before ack;
   replica engine mutation entry points are read-only except for internal replay.
   Promotion now rejects any received/replayed LSN gap and can require a
   caller-supplied recovery point. Active primary engine mutations validate the
   fencing lease before writing. Validate partitions and stale writers before
   adding automatic election.
5. Rails: populated migration round trips, eager loading, nested associations,
   connection pools and a supported-version CI matrix remain open. Migration
   tracking now uses stable content checksums and fails closed for changed or
   missing applied migrations. Native and ActiveRecord schema dumps now
   round-trip automatic/custom primary-key modes, defaults, and indexes through
   live engines.
6. Operations: backup manifest writes now use durable atomic publication, live
   engines flush WAL/storage before physical backup, and a scheduled restore
   drill reopens restored files. Upgrade tests, measured resource limits,
   alerting, and full security review remain open. Replication peers now
   support constant-time shared-token authentication when configured; TLS and
   credential rotation procedures still require deployment validation.

7. Release engineering: cross-platform Ruby 3.3/3.4 CI, the ActiveRecord
   adapter CI job, and a deterministic bounded fuzz safety workflow are now
   wired into GitHub Actions, and release provenance signing is enabled for gem
   artifacts. CI now enforces 25% line and 20% branch coverage (the current
   audit measured 62.0% line and 32.84% branch). Property-based generators, RubyGems
   gem-level signatures, and automated changelog/release publication remain
   open.

Deployment tests must record the commit, platform, workload and measured
results. Keep untested features marked as unvalidated.
