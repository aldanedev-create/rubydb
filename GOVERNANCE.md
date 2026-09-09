# RubyDB governance

RubyDB is maintained through reviewed changes in the public repository. The
maintainers are responsible for release decisions, security coordination,
compatibility claims, and accepting changes that affect data safety.

Changes to storage format, WAL, recovery, transaction isolation, replication,
authentication, protocol framing, or release automation require focused tests,
documentation, and an explicit operational-impact review.

Security vulnerabilities should be reported privately as described in
`SECURITY.md`. Public issues are appropriate for reproducible bugs that do not
expose an unpatched vulnerability.

The project follows semantic versioning while compatibility is still evolving.
Release tags must pass the protected CI and RubyGems release checks.
