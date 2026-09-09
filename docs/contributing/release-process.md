# Releasing RubyDB to RubyGems

1. Update `CHANGELOG.md`, bump the semantic version, and confirm the Ruby/Rails support matrix for the release.
2. Run the complete verification suite and workload test. The release workflow independently builds and validates the gem on a version tag.
3. Create a RubyGems API key with the minimum scope needed to push this gem. Store it as the `RUBYGEMS_API_KEY` GitHub Actions secret or in RubyGems' protected credentials file; never commit it.
4. Create and push an annotated `v<version>` tag. The release workflow publishes only when that tag's version matches `RubyDB::VERSION` and the secret is available.
5. To build, verify, and publish manually:

```sh
RUBYDB_PUBLISH=1 GEM_HOST_API_KEY=<RubyGems API key> ruby scripts/release
```

Without `RUBYDB_PUBLISH=1`, `ruby scripts/release` only rebuilds and verifies the gem/checksum.

The tag workflow also creates a signed GitHub build-provenance attestation for
the exact gem artifact. Verify that attestation in the repository's Actions or
Releases UI before distributing the package; the SHA-512 file remains available
for an independent byte-for-byte check.

Pull requests also run the supported Ruby 3.3/3.4 matrix on Linux, macOS, and
Windows, plus the ActiveRecord adapter suite. A scheduled bounded fuzz job runs
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
