# RubyDB documentation index

Start here:

- [Real-world copy-and-paste cookbook](real-world-examples.md)
- [Developer guide](developer-guide.md)
- [Troubleshooting](troubleshooting.md)
- [Debugging playbook](debugging.md)
- [Production operations guide](operations/production-guide.md)
- [Quick start](getting-started/quickstart.md)
- [Local development to production](getting-started/local-to-production.md)
- [First database](getting-started/first-database.md)
- [First query](getting-started/first-query.md)
- [Rails installation](rails/installation.md)
- [Rails production guidance](rails/production.md)
- [SQLite compatibility profile](sql/sqlite-compatibility.md)
- [SQL compatibility contract](sql/compatibility.md)
- [SQL compatibility guide](sql/compatibility-guide.md)
- [Rails compatibility guide](rails/compatibility-guide.md)
- [Python adapter](../adapters/python/README.md)
- [Production validation](production_validation.md)
- [Production-readiness audit](production-readiness.md)
- [Production runbook](operations/production-runbook.md)
- [CLI guide](cli.md)
- [CLI cheat sheet](cli-cheatsheet.md)
- [Immutable table export](export.md)
- [Disaster recovery](operations/disaster-recovery.md)
- [Monitoring and alerting](operations/monitoring.md)
- [Workload testing](operations/workload-testing.md)
- [Release checklist](release.md)
- [Lessons learned](lessons-learned.md)
- [Production journey](../lessons/01-foundations.md)
- [Build a community adapter](../lessons/11-community-adapter.md)
- [Python local runtime and production](../lessons/13-python-local-runtime.md)

Architecture and development:

- [Current-state audit](architecture/current-state.md)
- [Production roadmap](architecture/production-roadmap.md)
- [Architecture overview](architecture/overview.md)
- [Ruby + Go accelerator](architecture/go-accelerator.md)
- [Storage engine](architecture/storage-engine.md)
- [Transactions](architecture/transactions.md)
- [MVCC](architecture/mvcc.md)
- [WAL](architecture/wal.md)
- [Query planner](architecture/query-planner.md)
- [Testing guide](contributing/testing.md)
- [Release process](contributing/release-process.md)
- [Branching](developer/branching.md)

The root [README](../README.md) is the public project overview. The current
production claim is intentionally bounded by the tested features and the
deployment-specific validation described above.

## Documentation map

Use the guides for the complete workflow and the smaller pages for focused
reference:

* `getting-started/` gets a new Ruby or Rails application running.
* `sql/` defines syntax, types, expressions, transactions, joins, functions,
  and compatibility boundaries.
* `architecture/` explains storage, WAL, recovery, MVCC, indexes, planning,
  execution, server ownership, and replication.
* `developer/` covers local development, snapshots, branches, temporal data,
  database diffs, and implementation workflows.
* `rails/` covers installation, configuration, migrations, production use,
  compatibility, and troubleshooting.
* `server/` covers deployment, authentication, TLS, pooling, protocol, and
  operational behavior.
* `operations/` covers backups, restore drills, monitoring, workload tests,
  production procedures, and incident response.
* `../lessons/` is a guided beginner-to-production journey that combines local
  RubyDB, Rails, PostgreSQL, and hybrid microservice decisions.
* `contributing/` and the root policy files cover testing, release, governance,
  support, security, and contribution requirements.

If a topic page and an implementation disagree, treat executable tests and the
documented compatibility contract as the source of truth, then open an issue
to reconcile the documentation.

## Fast path for a new application

Choose the topology before copying an example:

```text
one Ruby process + local file      -> RubyDB.open("tmp/app.rdb")
web/workers/multiple processes    -> RubyDB server + RUBYDB_URL
large Rails application/unknown SQL -> PostgreSQL in production
```

The [real-world cookbook](real-world-examples.md) includes a runnable order
service, Rails configuration, server/TLS URL, backup drill, and workload
commands. It also states the operating boundaries of each topology so a local
development shortcut is not mistaken for a production deployment.
