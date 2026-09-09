# Releasing RubyDB to RubyGems

1. Update `CHANGELOG.md`, bump the semantic version, and confirm the Ruby/Rails support matrix for the release. The version must have a top-level `## <version>` changelog entry; the release preflight fails closed when it is missing.
2. Run the complete verification suite and workload test. The release workflow independently builds and validates the gem on a version tag.
3. Create a RubyGems API key with the minimum scope needed to push this gem. Store it as the `RUBYGEMS_API_KEY` GitHub Actions secret or in RubyGems' protected credentials file; never commit it.
4. Create and push an annotated `v<version>` tag. The compatibility workflow
   must pass its SimpleCov line-coverage gate, and the release workflow
   publishes only when that tag's version matches `RubyDB::VERSION` and the
   secret is available.
5. To build, verify, and publish manually:

```sh
RUBYDB_PUBLISH=1 GEM_HOST_API_KEY=<RubyGems API key> ruby scripts/release
```

Without `RUBYDB_PUBLISH=1`, `ruby scripts/release` only rebuilds and verifies the gem/checksum. Manual publication must also set `RUBYDB_RELEASE_VERSION=<version>`; tagged CI obtains that identity from `GITHUB_REF_NAME`.

The tag workflow also creates a signed GitHub build-provenance attestation for
the exact gem artifact. Verify that attestation in the repository's Actions or
Releases UI before distributing the package; the SHA-512 file remains available
for an independent byte-for-byte check.

For the tag release workflow, provision base64-encoded
`RUBYDB_GEM_SIGNING_KEY_B64` and `RUBYDB_GEM_CERT_B64` repository secrets. The
release job materializes them only on the ephemeral runner and passes the
protected paths to `gem build`; it never stores them in the repository. GitHub
release notes are generated from the tag history after publication, so review
the generated release before announcing it.

The tag workflow fails closed when the signing secrets or RubyGems publication
key are missing. Local unsigned builds remain available through `rake build`
and are not publication artifacts.

Pull requests also run the supported Ruby 3.3/3.4 matrix on Linux, macOS, and
Windows, plus the ActiveRecord adapter suite on Rails 7.1, 7.2, and 8.0. A scheduled bounded fuzz job runs
the SQL parser, WAL, storage, transaction, and query-engine fuzzers. Increase
`RUBYDB_FUZZ_ITERATIONS` locally when investigating a failure, retaining the
reported `RUBYDB_FUZZ_SEED` for reproduction.

The scheduled operations workflow runs `ruby scripts/restore_drill`, which
creates a live backup, verifies its manifest/checksums, restores it into a
separate directory, and reopens the restored database before succeeding.

After publication, install the exact released version in a clean environment and run a smoke test:

```sh
gem install rubydb --version 0.1.0
ruby -e "require 'rubydb'; puts RubyDB::VERSION"
```
