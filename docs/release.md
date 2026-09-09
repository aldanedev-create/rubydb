# RubyDB release checklist

The release workflow is intentionally fail-closed. A maintainer must configure
these protected GitHub Actions secrets:

- `RUBYGEMS_API_KEY`: a RubyGems API key scoped to the gem
- `RUBYDB_GEM_SIGNING_KEY_B64`: base64-encoded private signing key
- `RUBYDB_GEM_CERT_B64`: base64-encoded certificate chain

Create the signing key and certificate outside the repository, store them in a
secret manager, and rotate them according to the organization's key policy.
Never commit the private key or write it to a persistent workspace.

To publish, review `CHANGELOG.md`, commit the version, create a matching tag,
and let `.github/workflows/release.yml` run the full suite, build the gem,
verify its SHA-512 checksum, attest provenance, sign it, and publish it. A
local artifact check is:

```sh
ruby scripts/release_check
ruby scripts/release
```

The local command does not publish unless `RUBYDB_PUBLISH=1` and
`GEM_HOST_API_KEY` are explicitly set. Review the generated GitHub release
notes and the uploaded checksum before announcing a version.
