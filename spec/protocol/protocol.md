# Protocol specification notes

The server protocol is a bounded request/response protocol with handshake,
authentication, query execution, prepared statements, transaction controls,
health, metrics, and cancellation paths. The implementation source and protocol
tests are authoritative; this page records the safety requirements.

Every frame must be size-limited, malformed input must fail the request safely,
and a client must not be able to bypass authorization or transaction ownership.
Cancellation is scoped to the active request and must not cancel a sibling
connection. Use TLS and private networking in production.

## Copy/paste protocol test

```sh
bundle exec rspec spec/server_protocol_spec.rb spec/server_session_spec.rb spec/server_health_request_spec.rb
```
