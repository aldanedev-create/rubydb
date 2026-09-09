# RubyDB architecture

RubyDB is organized as a durable relational engine with optional server/client
and Rails integration layers:

1. SQL lexer/parser and AST
2. binder, planner, and executor
3. catalog, constraints, and indexes
4. transactions, MVCC, lock management, and WAL
5. page storage, checkpoints, recovery, backup, and compaction
6. server protocol, authentication, TLS, limits, and monitoring
7. logical replication, fencing, failover, and adapters

The architecture is deliberately modular so every durable boundary can be
tested independently and end to end. Start with the [architecture index](docs/README.md),
then read [current state](docs/architecture/current-state.md) and the
[production validation contract](docs/production_validation.md).

The embedded engine requires exclusive ownership. Server mode is the boundary
for multiple application processes. Automatic election is disabled until an
independent multi-host fencing authority is validated.
