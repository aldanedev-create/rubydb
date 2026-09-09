# Rails adapter installation

From the repository adapter directory:

```sh
cd adapters/activerecord
bundle install
bundle exec rspec
```

Add the adapter gem to the application bundle according to the release being
tested. Configure `adapter: rubydb` and a database path or server endpoint. Run
`db:migrate`, schema dump/load, representative joins, eager loading, nested
associations, and rollback tests before deployment.

The CI matrix currently exercises Rails 7.1, 7.2, and 8.0 with the supported
Ruby versions. Hosted results are the release evidence for a combination.
