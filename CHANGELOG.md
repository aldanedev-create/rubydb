# Changelog

All notable changes to RubyDB are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## Unreleased

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
