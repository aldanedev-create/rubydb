# RubyDB security policy

RubyDB is alpha software with a documented, tested feature set. Security
controls are implemented and tested for the server protocol, TLS transport,
password/SCRAM authentication, authorization, bounded frames, query deadlines,
resource limits, replication tokens, path validation, backup manifests, and
fencing. A deployment must still complete an independent security review
before it handles sensitive or regulated data.

## Secure deployment requirements

- Keep the database directory, WAL, backups, TLS private keys, authentication
  credentials, and replication state on protected storage with least-privilege
  filesystem ownership.
- Bind the server and replication listeners to explicit private addresses. Do
  not expose them directly to the public internet; restrict ingress with a
  firewall or private network.
- Enable TLS with TLS 1.2 or newer, validate the server certificate, and use a
  trusted CA or mutual TLS where the deployment requires peer identity.
- Use high-entropy credentials and a separate high-entropy replication token.
  Never put secrets in source control, URLs, shell history, logs, or bug
  reports.
- Configure maximum connections, request/frame sizes, query deadlines, and
  filesystem thresholds for the host. Treat readiness failure and recovery-
  required acknowledgements as incidents.
- Run backups with encryption approved by the organization, retain the
  manifest and WAL chain together, and perform restore drills into a new
  inactive directory.

## Rotation and incident response

Stage replacement certificates and credentials, validate them on a non-serving
instance, then rotate during a planned window. Drain clients or replication
peers, change both sides of a replication token, reconnect, and verify the
authentication-failure metric returns to baseline. Retain the old certificate
only for the documented overlap window and remove it afterward.

For suspected compromise, corruption, checksum failure, replication
divergence, or fencing anomalies: stop writes, isolate the affected node,
preserve the database/WAL/log files and timestamps, and create a verified copy
before attempting repair, vacuum, restore, or promotion. Automatic election is
disabled; never run two writable primaries without an externally verified
fencing lease.

## Reporting a vulnerability

Do not disclose unpatched vulnerabilities in a public issue. Use a private
GitHub security advisory for the repository or contact the maintainer listed in
the gem metadata with reproduction steps, affected versions, impact, and a
safe disclosure timeline. Do not include production secrets or customer data.

Security scans run in GitHub Actions, but scan results do not replace review of
deployment configuration, network policy, secret storage, certificate
lifecycle, or the host filesystem.
