# Connection pooling

The server limits active connections and queues work through its connection and
worker pools. Rails/client pool totals must fit below the server limit with
headroom for administrative and replication traffic.

Set finite acquisition, read, write, idle, and query timeouts. Alert on pool
wait, rejected connections, request failures, and saturation. Load-test pool
behavior with the multi-process and production soak harness; a successful local
connection does not prove capacity under application traffic.

## Copy/paste pool pressure

```sh
RUBYDB_WORKLOAD_THREADS=16 \
RUBYDB_WORKLOAD_OPERATIONS=10000 \
ruby benchmarks/concurrent_workload.rb
```

Set the workload thread count to the sum of application pools only after
leaving headroom for migrations, health checks, and replication.
