# Wire protocol test notes

Wire tests validate handshake, bounded frames, authentication, query responses,
prepared statements, deadlines, cancellation, health, metrics, and connection
cleanup. They use live TCP sessions where the behavior is network-facing.

Any protocol change must preserve safe rejection of malformed or oversized
frames, request isolation, timeout behavior, authorization, and clean server
shutdown. Update the server protocol guide when the wire contract changes.
