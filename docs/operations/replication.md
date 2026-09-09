# Replication operations

RubyDB replication is logical WAL row-mutation replication. Configure the
primary and replica with separate data directories, explicit network addresses,
and the same high-entropy `replication_auth_token`. Restrict the listener with
firewall rules and use TLS or a trusted private network; the token is peer
authentication, not a replacement for transport encryption.

## Bootstrap and catch-up

Start the primary first, then start the replica with its replica identifier and
primary address. The primary sends catalog schema before row replay. Verify the
replica reaches `SYNCED`, and compare received and replayed LSNs before routing
reads to it.

Monitor replication status continuously. A replica with a received/replayed
gap is not eligible for promotion. Preserve the replication log and replica
state files during an incident; do not manually edit LSN state.

## Token rotation

Drain replication, stop or disconnect the replica, update the protected token
on both sides, restart the primary listener if required, and reconnect the
replica. Confirm accepted handshakes and zero unexpected authentication
failures before returning the replica to service. Never place tokens in source
control or command histories.

## Failure handling

On a network partition, assume the old primary may still be reachable until it
is fenced. Do not promote a lagging replica and do not run two writable primaries
without a verified fencing lease. Re-bootstrap a divergent replica rather than
guessing which WAL records are safe to apply.
