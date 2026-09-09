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
- Added a documentation index and lessons-learned guide covering durability,
  ownership, replication fencing, cancellation, deadlocks, Rails adapters,
  operations, evidence, and security review boundaries.
- Added a full CLI guide and cheat sheet covering lifecycle, server operation,
  shell, migrations, backup/restore, snapshots, branches, inspection, doctor,
  vacuum, maintenance, and release workflows.
- Clarified the tested common SQLite-style profile and production limits.

## 0.1.0 - 2026-09-07

- Initial public release candidate.
- Includes the embedded engine, ActiveRecord adapter, backup/recovery, WAL,
  TLS, authentication, and validated production-hardening checkpoints.
- See `docs/production_validation.md` for tested scope and operational limits.
