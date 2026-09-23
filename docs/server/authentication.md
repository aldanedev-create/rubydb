# Server authentication

Configure authentication explicitly for production. Password/SCRAM-SHA-256,
authorization, peer replication tokens, bounded frames, TLS, and server
signature verification are covered by the security suite.

Use high-entropy credentials from a secret manager. Bind to a private address,
enable TLS 1.2 or newer, validate the CA and hostname, and rotate credentials
through a drain/reconnect procedure. Missing or incomplete authentication
configuration must fail startup rather than silently downgrade security.

## Copy/paste authenticated client check

Store the URL in a secret manager and run the check without committing it:

```sh
RUBYDB_URL='rubydbs://app_rw:URL_ENCODED_PASSWORD@db.internal:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt' \
ruby -rrubydb -e 'c=RubyDB::Client::Client.new(url: ENV.fetch("RUBYDB_URL")); p c.query("SELECT 1").to_hash; c.disconnect'
```
