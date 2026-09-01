# RubyDB

**A developer-first relational database for Ruby and Rails**

[![Ruby](https://img.shields.io/badge/ruby-4.0.6-red.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Build Status](https://github.com/rubydb/rubydb/workflows/CI/badge.svg)](https://github.com/rubydb/rubydb/actions)

RubyDB is a production-capable, developer-first relational database written in Ruby. It combines SQLite's developer experience with PostgreSQL's production capabilities, while being natively integrated with Ruby and Rails.

## Why RubyDB?

**The Problem:** PostgreSQL requires infrastructure setup, configuration, and maintenance even for development. SQLite can't handle production workloads with concurrency.

**The Solution:** RubyDB gives you SQLite-like simplicity during development with PostgreSQL-like production capabilities - all in a Ruby-native package.

### Key Philosophy

- **Simple like SQLite** - Zero configuration, single file, `gem install rubydb` and go
- **Production capable like PostgreSQL** - Transactions, concurrency, WAL, crash recovery, replication
- **Ruby/Rails native** - First-class ActiveRecord adapter, `rails new myapp -d rubydb`
- **Developer-first features** - Database branching, snapshots, time-travel queries, diffs

## Quick Start

### Installation

```bash
gem install rubydb
```

### Create a Database

```bash
rubydb create myapp
rubydb start myapp
```

```bash
RubyDB 0.1.0

Database: myapp
Mode: development
Storage: ./myapp.rdb

✓ Storage initialized
✓ WAL enabled
✓ Query engine ready
✓ Database ready

Listening on rubydb://localhost:7432
```

### Use with Ruby

```ruby
require 'rubydb'

# Connect to database
db = RubyDB.connect('rubydb://local/./myapp.rdb')

# Execute SQL
db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)')
db.execute("INSERT INTO users (name, email) VALUES ('John', 'john@example.com')")

# Query
results = db.query('SELECT * FROM users')
results.each do |row|
  puts "#{row['id']}: #{row['name']} (#{row['email']})"
end

# Transactions
db.transaction do
  db.execute("UPDATE users SET name = 'John Doe' WHERE id = 1")
  db.execute("INSERT INTO users (name, email) VALUES ('Jane', 'jane@example.com')")
end

# Close
db.close
```

### Use with Rails

```ruby
# Gemfile
gem 'rubydb'
gem 'rubydb-activerecord'
```

```yaml
# config/database.yml
development:
  adapter: rubydb
  database: db/development.rdb

test:
  adapter: rubydb
  database: db/test.rdb

production:
  adapter: rubydb
  url: <%= ENV["DATABASE_URL"] %>
```

```bash
rails new myapp -d rubydb
cd myapp
rails db:create
rails db:migrate
rails server
```

### Developer Workflow

```bash
# Database branching (Git-like workflow)
rubydb branch feature-auth
rubydb checkout feature-auth

# Work on your feature...

# Create a snapshot before risky changes
rubydb snapshot before-migration

# Migrate and test
rails db:migrate

# Something wrong? Rollback
rails db:rollback
rubydb restore before-migration

# Merge your changes
rubydb checkout main
rubydb merge feature-auth
```

## Features

### Core Database

- **Full SQL Support**: SELECT, INSERT, UPDATE, DELETE with JOINs, subqueries, aggregations
- **ACID Transactions**: Full transaction support with commit/rollback
- **MVCC**: Multi-Version Concurrency Control for isolation
- **WAL**: Write-Ahead Logging for durability
- **Crash Recovery**: Automatic recovery from crashes
- **B-Tree Indexes**: Fast lookups with B-Tree indexing
- **Constraints**: PRIMARY KEY, FOREIGN KEY, UNIQUE, NOT NULL, CHECK
- **Data Types**: INTEGER, BIGINT, SMALLINT, FLOAT, DECIMAL, BOOLEAN, TEXT, VARCHAR, BLOB, DATE, TIME, TIMESTAMP, JSON, UUID

### Developer Features

- **Database Branching**: Git-like branching for databases
- **Time-Travel Queries**: `SELECT * FROM users AS OF '2026-08-01'`
- **Snapshots**: Point-in-time snapshots with rollback
- **Database Diff**: Compare branches and schemas
- **Incremental Backups**: Efficient incremental backups
- **Migration Support**: Rails-style migrations

### Production Features

- **Server Mode**: Network server with connection pooling
- **Authentication**: Password, MD5, SCRAM-SHA-256
- **Authorization**: Role-based access control
- **Replication**: Primary-replica replication with failover
- **WAL Archiving**: Automatic WAL archiving and restore
- **Monitoring**: Metrics, health checks, performance monitoring
- **Backup/Restore**: Full, incremental, and differential backups

### Ruby/Rails Integration

- **First-Class Rails Adapter**: Full ActiveRecord support
- **Rake Tasks**: `rails db:create`, `rails db:migrate`, `rails db:rollback`
- **Migrations**: Rails-style migrations
- **Associations**: Has many, belongs to, has one
- **Validations**: ActiveRecord validations
- **Transactions**: ActiveRecord transactions

## Architecture

```
                        Ruby / Rails Application
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                ActiveRecord                Ruby Client
                    │                           │
                    └─────────────┬─────────────┘
                                  │
                            RubyDB Protocol
                                  │
                         ┌────────▼────────┐
                         │  RubyDB Server  │
                         └────────┬────────┘
                                  │
                         ┌────────▼────────┐
                         │   SQL Engine    │
                         │                 │
                         │ Lexer           │
                         │ Parser          │
                         │ AST             │
                         │ Planner         │
                         │ Optimizer       │
                         └────────┬────────┘
                                  │
                         ┌────────▼────────┐
                         │ Execution Engine │
                         └────────┬────────┘
                                  │
                ┌─────────────────┼─────────────────┐
                │                 │                 │
           Transactions         MVCC            Constraints
                │                 │                 │
                └─────────────────┼─────────────────┘
                                  │
                         ┌────────▼────────┐
                         │ Storage Engine  │
                         └────────┬────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
                 Indexes                       WAL
                    │                           │
                    └─────────────┬─────────────┘
                                  │
                              Disk / SSD
```

## Documentation

- [Getting Started](docs/getting-started/)
- [SQL Reference](docs/sql/)
- [Rails Integration](docs/rails/)
- [Architecture](docs/architecture/)
- [Operations](docs/operations/)
- [Development](docs/developer/)
- [Contributing](docs/contributing/)

## Roadmap

### Phase 1 - Core Database (v0.1)
- ✅ Storage engine
- ✅ SQL parser
- ✅ Query execution
- ✅ Transactions
- ✅ WAL
- ✅ Crash recovery
- ✅ Indexes
- ✅ Constraints
- ✅ Data types

### Phase 2 - Rails Integration (v0.2)
- ✅ ActiveRecord adapter
- ✅ Migrations
- ✅ Rails integration
- ✅ Client library

### Phase 3 - Production (v0.3)
- ✅ Server mode
- ✅ Authentication/Authorization
- ✅ Replication
- ✅ Backup/Restore
- ✅ Monitoring

### Phase 4 - Developer Features (v0.4+)
- ✅ Database branching
- ✅ Time-travel queries
- ✅ Snapshots
- ✅ Database diff
- ✅ Incremental backups

## Comparison

| Feature | SQLite | RubyDB | PostgreSQL |
|---------|--------|--------|------------|
| Setup | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| Local Development | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| Rails Integration | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Production Workloads | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Concurrency | ⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| SQL Support | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Database Branching | ❌ | ✅ | ❌ |
| Time-Travel Queries | Limited | ✅ | Extensions |
| Developer Tooling | ⭐⭐⭐ | Built-in | ⭐⭐⭐ |
| Language | C | Ruby | C |

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md).

### Development Setup

```bash
git clone https://github.com/rubydb/rubydb.git
cd rubydb
bundle install
bundle exec rake spec
```

### Running Tests

```bash
# Unit tests
bundle exec rake spec

# Integration tests
bundle exec rake spec:integration

# Crash tests
bundle exec rake spec:crash

# Fuzz tests
bundle exec rake fuzz
```

## License

RubyDB is released under the [MIT License](LICENSE).

## Support

- [GitHub Issues](https://github.com/rubydb/rubydb/issues)
- [Discussions](https://github.com/rubydb/rubydb/discussions)
- [Documentation](https://rubydb.dev)

## Acknowledgments

RubyDB draws inspiration from:
- **SQLite** - Simplicity and developer experience
- **PostgreSQL** - Production features and reliability
- **Rails** - Ruby-first developer experience
- **Datomic** - Data history and time-travel queries
- **Git** - Branching workflow

---

Made with ❤️ by the Aldane Hutchinson