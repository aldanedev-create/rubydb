# Development guide

Install dependencies with `bundle install`. Run focused specs while developing,
then run `bundle exec rspec` and `bundle exec rubocop` before opening a pull
request. Keep test databases in temporary directories and close engines in
`ensure` blocks.

Never use production data or secrets in local tests. Changes that affect a
stored format, SQL behavior, protocol, migration, or release process must update
the corresponding documentation and changelog.

For the complete change workflow, read the [developer guide](../developer-guide.md),
[debugging playbook](../debugging.md), and [testing guide](testing.md). Every
bug fix should include a regression test and an explanation of its invariant.
Run fault, concurrency, or recovery tests when the change crosses a durable
boundary; a unit test alone is not sufficient evidence.
