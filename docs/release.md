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
`GEM_HOST_API_KEY` are explicitly set. Publishing also requires the release
version to be supplied when you are not running from a matching Git tag.

On Windows PowerShell, run this from the repository root:

```powershell
$env:RUBYDB_RELEASE_VERSION = "0.1.0"
$env:RUBYDB_PUBLISH = "1"
$env:GEM_HOST_API_KEY = "YOUR_RUBYGEMS_API_KEY"
ruby scripts/release
```

Instead of `GEM_HOST_API_KEY`, RubyGems can read a credentials file. With the
RubyGems version bundled with Ruby 4 on Windows, create this file:
`C:\Users\<your-user>\.local\share\gem\credentials`

```yaml
---
:rubygems_api_key: YOUR_RUBYGEMS_API_KEY
```

Then omit `GEM_HOST_API_KEY`; `scripts/release` and `gem push` will use the
file automatically. Keep the file private and never commit it.

On macOS/Linux, use:

```sh
RUBYDB_RELEASE_VERSION=0.1.0 \
RUBYDB_PUBLISH=1 \
GEM_HOST_API_KEY="YOUR_RUBYGEMS_API_KEY" \
ruby scripts/release
```

Never commit the API key or put it in a tracked file. Review the generated
GitHub release notes and uploaded checksum before announcing a version.
