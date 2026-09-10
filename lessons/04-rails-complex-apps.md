# Lesson 4: Rails and complex application code

RubyDB can be useful for a Rails application when the application stays within
the adapter’s tested surface. Complex Rails code is still possible, but every
important query and migration must be exercised against the exact database
topology you will deploy.

## Pin the adapter and configure the boundary

```ruby
# Gemfile
gem "rubydb", "0.1.5"
gem "rubydb-activerecord", "0.1.2"
```

Embedded development configuration:

```yaml
# config/database.yml
development:
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/development.rdb") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>

test:
  adapter: rubydb
  embedded: true
  database: <%= Rails.root.join("tmp/test.rdb") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

For server mode, use one connection URL supplied by the deployment:

```yaml
production:
  adapter: rubydb
  embedded: false
  url: <%= ENV.fetch("RUBYDB_URL") %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", "5") %>
```

The RubyDB adapter URL is `rubydb://` or TLS-enabled `rubydbs://`; it is not a
PostgreSQL `DATABASE_URL`.

## Associations, joins, and eager loading

Start with ordinary Rails models:

```ruby
class Account < ApplicationRecord
  has_many :projects, dependent: :destroy
end

class Project < ApplicationRecord
  belongs_to :account
  has_many :tasks, dependent: :destroy

  scope :active, -> { where(status: "active") }
end

class Task < ApplicationRecord
  belongs_to :project
end
```

Exercise both the SQL shape and the object-loading behavior:

```ruby
accounts = Account
  .joins(:projects)
  .merge(Project.active)
  .where(projects: { archived: false })
  .includes(projects: :tasks)
  .distinct
  .order(:name)

accounts.each do |account|
  account.projects.each do |project|
    puts [account.name, project.name, project.tasks.size].join(" | ")
  end
end
```

This example is a validation target, not a promise that every Arel variation
or database-specific query will work. Add request or model tests that assert
the result set, duplicate behavior, `NULL` behavior, ordering, and query count.

## Transactions and migrations

Keep a transaction around a business operation and make retry behavior
explicit:

```ruby
ApplicationRecord.transaction do
  project = Project.create!(account: account, name: "Billing", status: "active")
  project.tasks.create!(title: "Verify invoice", state: "open")
end
```

A migration must be safe on an empty and populated database:

```ruby
class AddStateToTasks < ActiveRecord::Migration[7.2]
  def change
    add_column :tasks, :state, :string, null: false, default: "open"
    add_index :tasks, [:project_id, :state]
  end
end
```

For a large table, test the migration duration, lock behavior, disk usage, and
rollback boundary on a restored copy. Do not assume a migration that succeeds
on an empty local file is safe during live traffic.

## The compatibility test matrix

Run the application suite for every supported combination, including the
database actually used in production:

```sh
bundle exec rails db:drop db:create db:migrate
bundle exec rails test
bundle exec rails db:schema:dump
```

Repeat that sequence with RubyDB embedded, RubyDB server/client, and
PostgreSQL when all three are supported. Compare schema dumps and test
business behavior, not merely process exit codes. Rails versions and adapter
versions should be pinned in CI; the project’s compatibility guide is the
source of truth for the currently tested matrix.

## Checkpoint

The checkpoint passes when your suite covers joins, eager loading, nested
associations, transactions, constraints, indexes, a populated-table
migration, schema dump/load, and error handling. Continue to [lesson 5](05-rubydb-production-server.md)
to run the same application through a private RubyDB server.
