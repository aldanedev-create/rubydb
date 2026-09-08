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

After publication, install the exact released version in a clean environment and run a smoke test:

```sh
gem install rubydb --version 0.1.0
ruby -e "require 'rubydb'; puts RubyDB::VERSION"
```
