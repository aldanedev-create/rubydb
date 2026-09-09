# RubyDB server protocol

The client/server protocol uses bounded framed requests and responses with
handshake, authentication, query, prepared statement, transaction, health, and
metrics operations. Frames must be size-limited and malformed input must be
rejected without taking down the server.

Query deadlines and in-flight cancellation are request-scoped. Cancellation is
cooperative and must be checked by long-running execution paths. Do not expose
the listener publicly; use TLS/private networking and rotate credentials through
the documented operations procedure. The normative notes are in
`spec/wire/protocol.md` and `spec/protocol/protocol.md`.
