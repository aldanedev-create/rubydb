# Changelog

All notable changes to RubyDB are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## Unreleased

- Removed full-table constraint probes from normal primary-key, unique, and
  foreign-key validation by maintaining automatic constraint indexes and a
  direct row locator. Generated integer keys and live `COUNT(*)` metadata now
  persist across reopen instead of repeatedly scanning a table.
- Added bounded microservice hot-path and insert-scaling specifications plus
  JSON benchmark scripts for point reads, limits, counts, keyed writes, and
  immutable export A/B measurements.
- Added immediate asynchronous WAL shutdown notification so normal process
  close no longer waits for a fixed polling interval.
- Added `rubydb export`: checksum-verified, detached immutable snapshot
  streaming to JSONL or CSV with atomic output, Ruby reference fallback,
  Go/Ruby parity coverage, filter-only fields, and production documentation.
- Corrected Go snapshot decoding for RubyDB's little-endian float storage and
  variable-length UUID values, and added streaming page/boolean filter tests.

## 0.1.7 - 2026-09-20

- Added the Python local-runtime package and `rubydb-python` 0.1.1 extras:
  platform-specific Ruby/Go bundles, local lifecycle commands, authenticated
  loopback connections, integrity checks, installed-wheel tests and packaging CI.
- Exposed the listener's actual bound port for race-free local port allocation.
- Added a Python local-development and production lesson. Distribution of the
  new runtime wheels is a separate release step.
- Fixed Go accelerator startup when its bundled executable path contains
  spaces, including Python runtime cache directories on Windows.

- Added full developer, troubleshooting, debugging, production operations,
  Rails compatibility, and SQL compatibility guides with repository maps,
  incident evidence procedures, safe recovery guidance, and deployment
  checklists.
- Added RubyDB connection URLs (`rubydb://` and TLS-enabled `rubydbs://`) for
  regular Ruby clients and Rails `database.yml`, including percent-encoded
  credentials and documented TLS/query options.
- Added a beginner-friendly local-to-production guide covering local RubyDB,
  PostgreSQL migration, RubyDB server deployment, environment URLs, Render-style
  hosting, data transfer, smoke tests, and production checklists.
- Added a documentation index and lessons-learned guide covering durability,
  ownership, replication fencing, cancellation, deadlocks, Rails adapters,
  operations, evidence, and security review boundaries.
- Added a full CLI guide and cheat sheet covering lifecycle, server operation,
  shell, migrations, backup/restore, snapshots, branches, inspection, doctor,
  vacuum, maintenance, and release workflows.
- Clarified the tested common SQLite-style profile and production limits.

## 0.1.6 - 2026-09-18

- Bundled the Go accelerator binaries and Ruby bridge for release installs;
  developers do not need Go installed to use the packaged core gem.
- Added lock-protected direct storage snapshots, worker lifecycle recovery,
  multiplexed requests, cancellation, bounded execution, and adaptive Ruby/Go
  selection with a safe Ruby fallback.
- Added accelerator CLI diagnostics, environment-mode handling, checksums,
  extracted-gem verification, and release packaging for the runtime binaries.
- Added the Rails ecommerce pressure example and expanded production guidance
  for embedded development, managed RubyDB services, PostgreSQL-backed large
  applications, and ActiveRecord adapter deployment.
- Prepared `rubydb-activerecord` 0.1.3 for the RubyDB 0.1.x release line.

## 0.1.5 - 2026-09-10

- Applied network query and prepared-statement parameters through the server
  protocol before SQL parsing, using shared safe literal binding rules.
- Added the initial Python DB-API adapter and live protocol validation under
  `adapters/python`.
- Added a ten-lesson guided journey with copy-and-paste development,
  PostgreSQL, RubyDB server, Rails, microservice, recovery, security, and
  release examples.
- Expanded the lesson journey with a direct RubyDB-to-production deployment
  path covering persistent storage, TLS, secrets, migrations, smoke tests,
  backup/restore, canary traffic, and rollback evidence.
- Added the initial `rubydb-python` DB-API 2.0 adapter under
  `adapters/python`, including TLS URLs, prepared statements, transactions,
  pooling, timeouts, cancellation, tests, and PyPI build instructions.

## 0.1.4 - 2026-09-09

- Returned logical generated primary-key values to ActiveRecord separately
  from physical storage row identifiers, including after deletes.
- Preserved generated insert identifiers through the RubyDB result boundary.

## 0.1.3 - 2026-09-09

- Normalized numeric MVCC visibility-map keys after restart to prevent mixed
  string/integer keys and duplicate-key warnings on Ruby 4.
- Made visibility-map persistence failures raise `RubyDB::StorageError`
  instead of silently reporting success.

## 0.1.2 - 2026-09-09

- Added SQLite/ActiveRecord-compatible `INSERT ... DEFAULT VALUES` parsing,
  planning, execution, default materialization, and regression coverage.
- Normalized literal schema defaults before they reach physical rows so empty
  strings and other scalar defaults are not persisted as AST wrapper objects.
- Released `rubydb-activerecord` 0.1.1 with scalar default unwrapping for
  ActiveRecord column metadata.

## 0.1.1 - 2026-09-09

- Published the Rails connection configuration fixes for embedded database
  paths and `rubydb://`/`rubydbs://` connection URLs.
- Kept the patch release compatible with the RubyDB 0.1.x adapter dependency
  range.

## 0.1.0 - 2026-09-07

- Initial public release candidate.
- Includes the embedded engine, ActiveRecord adapter, backup/recovery, WAL,
  TLS, authentication, and validated production-hardening checkpoints.
- See `docs/production_validation.md` for tested scope and operational limits.
