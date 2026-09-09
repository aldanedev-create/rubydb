# Concurrency architecture

Threads coordinate through locks, transaction ownership, the lock manager,
buffer-pool synchronization, and server worker/connection limits. Transactions
have connection-scoped state in server mode; the embedded owner remains one
process.

The lock manager detects wait-for cycles and selects a victim. The transaction
manager rolls the victim back, releases its locks, and returns a retryable
deadlock error. Timeouts and cancellation are distinct: a timeout stops a
request deadline, while wire cancellation actively marks an in-flight request.

Validate concurrency with the production soak, multi-process workload, latency
percentiles, deadlock checks, resource limits, and durable reopen verification.
