# Server architecture

The server owns one embedded engine and exposes client sessions over the RubyDB
protocol. A listener accepts bounded connections, a connection pool tracks
active sessions, and a worker pool handles requests under configured limits.

Lifecycle shutdown stops acceptance, closes connections, joins workers, flushes
the engine, and removes the PID file. Multiple application processes should
share the server, not the embedded path. Use health/readiness and Prometheus
metrics to decide whether to route traffic.
