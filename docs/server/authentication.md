# Server authentication

Configure authentication explicitly for production. Password/SCRAM-SHA-256,
authorization, peer replication tokens, bounded frames, TLS, and server
signature verification are covered by the security suite.

Use high-entropy credentials from a secret manager. Bind to a private address,
enable TLS 1.2 or newer, validate the CA and hostname, and rotate credentials
through a drain/reconnect procedure. Missing or incomplete authentication
configuration must fail startup rather than silently downgrade security.
