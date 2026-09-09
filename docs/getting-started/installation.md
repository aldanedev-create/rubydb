# Installation

RubyDB requires Ruby 3.3 or newer in the current support policy.

```sh
gem install rubydb --pre
```

From a checkout:

```sh
bundle install
bundle exec rspec
```

For Rails, install the adapter from `adapters/activerecord` and use the
configuration documented in `docs/rails/database-yml.md`. Pin RubyDB and Ruby
versions in production and test the exact gem on a restored staging backup
before deployment.
