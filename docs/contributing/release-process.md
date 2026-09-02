# Releasing RubyDB to RubyGems

1. Replace the placeholder author, email, homepage, source-code, and changelog URLs in `rubydb.gemspec`, `adapters/activerecord/rubydb-activerecord.gemspec`, and `packaging/homebrew/rubydb.rb` with the project owner's real values.
2. Run the complete verification suite and workload test.
3. Create a RubyGems API key with the minimum scope needed to push this gem. Keep it in `GEM_HOST_API_KEY` or RubyGems' protected credentials file; never commit it.
4. Build, verify, and publish:

```sh
RUBYDB_PUBLISH=1 GEM_HOST_API_KEY=<RubyGems API key> ruby scripts/release
```

Without `RUBYDB_PUBLISH=1`, `ruby scripts/release` only rebuilds and verifies the gem/checksum. The script deliberately refuses publication while the gemspec contains placeholder project URLs.

After publication, install the exact released version in a clean environment and run a smoke test:

```sh
gem install rubydb --version 0.1.0
ruby -e "require 'rubydb'; puts RubyDB::VERSION"
```
