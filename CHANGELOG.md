# Changelog

All notable changes to RubyDB are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## Unreleased

- Added a documentation index and lessons-learned guide covering durability,
  ownership, replication fencing, cancellation, deadlocks, Rails adapters,
  operations, evidence, and security review boundaries.
- Clarified the tested common SQLite-style profile and production limits.

## 0.1.0 - 2026-09-07

- Initial public release candidate.
- Includes the embedded engine, ActiveRecord adapter, backup/recovery, WAL,
  TLS, authentication, and validated production-hardening checkpoints.
- See `docs/production_validation.md` for tested scope and operational limits.
