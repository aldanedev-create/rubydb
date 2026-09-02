# RubyDB WAL format

Each WAL segment is a sequence of independently framed records:

```text
4-byte unsigned big-endian payload length
16-byte ASCII SHA-256 checksum prefix
UTF-8 JSON payload
```

The checksum covers the JSON payload only. A record's LSN offset is the byte
offset of its frame header within the segment, so readers can advance exactly
one frame at a time. If the final frame is incomplete, recovery stops at that
tail and retains all complete preceding records.

WAL data is flushed and fsynced before the storage engine flushes data pages
when synchronous WAL mode is enabled (the default). A successful `write` is
therefore durable only after the WAL sync completes; callers must still use
the engine's transaction/close APIs to coordinate higher-level durability.

## Transaction recovery records

Mutation records include the transaction ID. UPDATE records include the
previous column values, and DELETE records include the previous row values and
columns. Recovery replays mutations for transactions with a durable COMMIT
record. Transactions that have a BEGIN but no COMMIT are undone in reverse WAL
order. Recovery uses the existing row version for DELETE undo and does not
create a replacement row with a new identifier.
