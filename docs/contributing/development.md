# Development guide

Install dependencies with `bundle install`. Run focused specs while developing,
then run `bundle exec rspec` and `bundle exec rubocop` before opening a pull
request. Keep test databases in temporary directories and close engines in
`ensure` blocks.

Never use production data or secrets in local tests. Changes that affect a
stored format, SQL behavior, protocol, migration, or release process must update
the corresponding documentation and changelog.
