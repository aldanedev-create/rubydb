# Architecture overview

RubyDB separates logical query processing from durable state changes. SQL is
lexed into tokens, parsed into an AST, bound against catalog metadata, planned,
and executed against the storage engine. DML is coordinated with transactions
and WAL before durable acknowledgement.

The catalog defines tables, columns, constraints, views, and indexes. The page
manager and buffer pool provide durable storage. Recovery replays valid WAL and
rejects malformed or uncertain state. Server/client mode isolates application
processes from the exclusive embedded owner.

Read the [current-state audit](current-state.md) before relying on any feature.
