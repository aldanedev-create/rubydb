# RubyDB examples

Every Ruby file in this directory is executable against the checked-out source
tree. Run commands from the repository root with `ruby path/to/example.rb`.

## Embedded and SQL examples

- `basic/create_database.rb [path]` creates a durable database and re-runnable
  schema/data.
- `basic/create_table.rb` creates a constrained table and unique index.
- `basic/queries.rb` runs a join and grouped aggregate.
- `basic/transactions.rb` demonstrates commit and rollback.
- `embedded/application.rb` uses the Ruby storage API and reopens the file.

## Operational examples

- `branching/workflow.rb` creates a branch and checks out a logical change.
- `replication/setup.rb` starts a local primary/replica and verifies catch-up.
- `server/server.rb` starts a TCP server; run `server/client.rb` in another
  terminal to execute a query.
- `production_smoke/` contains regular Ruby and Rails application smoke tests.
- `rails_app/` and `github_clone/` contain complete small Rails applications.
- `python_flask/` is a real Flask JSON API using `rubydb-python`.
- `python_flaxon/` is a real async Flaxon JSON API using `rubydb-python`.
- The repository's `adapters/rubydb/` contains the TypeScript/Node.js client
  package and protocol tests for `rubydb-node`.

The Python examples require a running RubyDB server and use `RUBYDB_URL`; see
each directory's README for setup, schema initialization, and live tests.

The branching and replication examples use temporary directories and clean up
after successful runs. The server example stores data under
`examples/server/tmp/server_data`; that path is ignored by Git. Do not open the
same embedded database path from multiple application processes; use the
server/client example for that topology.
