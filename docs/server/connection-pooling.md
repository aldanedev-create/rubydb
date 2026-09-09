# Connection pooling

The server limits active connections and queues work through its connection and
worker pools. Rails/client pool totals must fit below the server limit with
headroom for administrative and replication traffic.

Set finite acquisition, read, write, idle, and query timeouts. Alert on pool
wait, rejected connections, request failures, and saturation. Load-test pool
behavior with the multi-process and production soak harness; a successful local
connection does not prove capacity under application traffic.
