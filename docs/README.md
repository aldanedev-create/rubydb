# RubyDB documentation index

Start here:

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
- [Production validation](production_validation.md)
- [Production-readiness audit](production-readiness.md)
- [Production runbook](operations/production-runbook.md)
- [CLI guide](cli.md)
- [CLI cheat sheet](cli-cheatsheet.md)
- [Disaster recovery](operations/disaster-recovery.md)
- [Monitoring and alerting](operations/monitoring.md)
- [Workload testing](operations/workload-testing.md)
- [Release checklist](release.md)
- [Lessons learned](lessons-learned.md)

Architecture and development:

- [Current-state audit](architecture/current-state.md)
- [Production roadmap](architecture/production-roadmap.md)
- [Architecture overview](architecture/overview.md)
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
* `contributing/` and the root policy files cover testing, release, governance,
  support, security, and contribution requirements.

If a topic page and an implementation disagree, treat executable tests and the
documented compatibility contract as the source of truth, then open an issue
to reconcile the documentation.
