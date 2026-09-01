# RubyDB

**⚠️ ALPHA - NOT PRODUCTION READY ⚠️**

A developer-first relational database for Ruby and Rails - currently in active development.

[![Ruby](https://img.shields.io/badge/ruby-4.0.6-red.svg)](https://www.ruby-lang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-alpha-orange.svg)](https://github.com/rubydb/rubydb)
[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](https://github.com/rubydb/rubydb/actions)

---

## ⚠️ IMPORTANT: ALPHA STATUS ⚠️

**RubyDB is currently in ALPHA development. It is NOT production ready.**

### Current State
- **Architecture**: Complete design and implementation
- **Storage Engine**: Partial implementation
- **SQL Parser**: Basic SQL support
- **Transactions**: Placeholder implementation
- **WAL**: Partial implementation
- **Replication**: Placeholder implementation
- **Tests**: Unit tests exist, integration tests incomplete
- **Performance**: Not optimized
- **Stability**: Not production ready

### Known Issues
- Storage persistence is incomplete
- Crash recovery does not work correctly
- MVCC is not fully implemented
- Query optimizer is basic
- No proper isolation level enforcement
- Replication is not functional
- Performance is not production grade
- Security features are not fully integrated

### When Will It Be Ready?
**Estimated timeline: 6-12 months with active development**

| Phase | Status | Timeline |
|-------|--------|----------|
| Core Database | ⏳ In Progress | 2-4 months |
| Rails Integration | ⏳ In Progress | 1-2 months |
| Production Features | ⏸️ Planned | 2-3 months |
| Developer Features | ⏸️ Planned | 1-2 months |

---

## What RubyDB Aims To Be

RubyDB is designed to combine:
- **SQLite's simplicity** - Zero configuration, single file, easy to start
- **PostgreSQL's capabilities** - Transactions, concurrency, replication
- **Ruby/Rails native experience** - First-class integration

### Target Audience
- **Rails Developers** - Local development, testing, and small production apps
- **Ruby Developers** - Embeddable database for Ruby applications
- **Students** - Learning database internals through Ruby
- **Prototypes** - Quick development with a real database

---

## Quick Start (Alpha Version)

### Installation
```bash
gem install rubydb --pre
```

### Create a Database
```bash
rubydb create myapp
rubydb start myapp
```

### Use with Ruby
```ruby
require 'rubydb'

db = RubyDB.connect('rubydb://local/./myapp.rdb')

# Basic operations (limited functionality in alpha)
db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)')
db.execute("INSERT INTO users (name) VALUES ('John')")
db.query('SELECT * FROM users')
```

### Use with Rails
```ruby
# Gemfile
gem 'rubydb', require: false  # Experimental Rails support
```

---

## Features Status

### ✅ Implemented (Partial/Basic)
- [x] Basic SQL parsing (SELECT, INSERT, UPDATE, DELETE)
- [x] Storage engine foundation
- [x] Page-based storage
- [x] Buffer pool
- [x] WAL foundation
- [x] Transaction foundation
- [x] Basic CLI
- [x] Ruby client
- [x] Basic data types

### ⚠️ In Progress
- [ ] Complete SQL support (JOINs, subqueries, window functions)
- [ ] Full MVCC implementation
- [ ] Complete WAL with crash recovery
- [ ] Query optimizer
- [ ] Index support (B-Tree)
- [ ] Constraints enforcement
- [ ] Rails adapter

### ❌ Not Yet Started
- [ ] Replication
- [ ] High availability
- [ ] Full security
- [ ] Backup/restore
- [ ] Monitoring
- [ ] Performance optimization

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐   │
│  │   Ruby Client   │  │   Rails Adapter │  │   Protocol Client   │   │
│  └────────┬────────┘  └────────┬────────┘  └──────────┬──────────┘   │
└───────────┼─────────────────────┼───────────────────────┼──────────────┘
            │                     │                       │
            ▼                     ▼                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       SERVER & PROTOCOL LAYER                          │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │              RubyDB Protocol (JSON/Binary)                     │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         SQL ENGINE LAYER                               │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌───────────────────┐│  │
│  │  │  Lexer  │─▶│ Parser  │─▶│  AST    │─▶│    Planner       ││  │
│  │  └─────────┘  └─────────┘  └─────────┘  │  ┌─────────────┐  ││  │
│  │                                          │  │  Optimizer  │  ││  │
│  │                                          │  └─────────────┘  ││  │
│  │                                          └───────────────────┘│  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       EXECUTION LAYER                                  │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │  │
│  │  │  SELECT  │  │  INSERT  │  │  UPDATE  │  │   DELETE     │  │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      TRANSACTION LAYER                                 │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  ┌────────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐  │  │
│  │  │ Transaction│  │    Lock    │  │   MVCC   │  │Isolation │  │  │
│  │  │  Manager   │  │  Manager   │  │          │  │  Levels  │  │  │
│  │  └────────────┘  └────────────┘  └──────────┘  └──────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        STORAGE LAYER                                   │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │  │
│  │  │  Buffer  │  │   Page   │  │   WAL    │  │   Recovery   │  │  │
│  │  │   Pool   │  │  Manager │  │          │  │              │  │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           DISK LAYER                                   │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │  │
│  │  │  *.rdb   │  │*.rdb-wal │  │*.rdb-shm │  │   *.backup   │  │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Comparison (Target - Not Current)

| Feature | SQLite | RubyDB (Alpha) | PostgreSQL |
|---------|--------|----------------|------------|
| Setup | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| Local Development | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| Rails Integration | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Production Workloads | ⭐⭐ | ❌ | ⭐⭐⭐⭐⭐ |
| Concurrency | ⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| SQL Support | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| Database Branching | ❌ | ⭐⭐ | ❌ |
| Time-Travel Queries | Limited | ⭐⭐ | Extensions |
| Stability | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| Performance | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## Development Status

### Current Focus (Q3-Q4 2026)
1. **Complete storage persistence** - Make data actually save to disk
2. **Implement MVCC** - Proper multi-version concurrency control
3. **Complete WAL** - Working write-ahead log with recovery
4. **SQL parser improvements** - More complete SQL support
5. **Query optimizer** - Cost-based optimization

### Next Priorities (Q1 2027)
1. **Rails adapter** - Full ActiveRecord integration
2. **Index support** - Working B-Tree indexes
3. **Constraints** - Complete constraint enforcement
4. **Security** - Authentication and authorization

### Future Goals (Q2-Q3 2027)
1. **Replication** - Primary-replica support
2. **Backup/restore** - Complete backup system
3. **Monitoring** - Metrics and health checks
4. **Performance optimization** - Production performance

---

## Contributing

We welcome contributors! Please see our [Contributing Guide](CONTRIBUTING.md).

### Areas Needing Help
1. **Storage Engine** - Make persistence work
2. **SQL Parser** - Complete SQL support
3. **MVCC** - Implement versioning properly
4. **Testing** - Add comprehensive tests
5. **Documentation** - User and API docs
6. **Performance** - Optimize Ruby code
7. **Rails Integration** - Make adapter work

### Development Setup
```bash
git clone https://github.com/rubydb/rubydb.git
cd rubydb
bundle install
bundle exec rake spec
```

---

## Documentation

- [Architecture](docs/architecture/) - Complete architecture overview
- [Getting Started](docs/getting-started/) - Alpha setup guide
- [Development](docs/contributing/) - Development guide
- [API Reference](docs/api/) - API documentation

---

## License

RubyDB is released under the [MIT License](LICENSE).

---

## Acknowledgments

RubyDB draws inspiration from:
- **SQLite** - Simplicity and developer experience
- **PostgreSQL** - Production features and reliability  
- **Rails** - Ruby-first developer experience
- **Datomic** - Data history and time-travel queries
- **Git** - Branching workflow

---

## Disclaimer

**⚠️ RubyDB is currently in ALPHA development. It is NOT PRODUCTION READY.**

- Data loss is possible
- API may change without notice
- Features may be incomplete
- Performance is not optimized
- Security is not fully implemented
- Not recommended for production use

Use at your own risk in development and testing environments only.

---

## Contact

- **GitHub**: [https://github.com/rubydb/rubydb](https://github.com/rubydb/rubydb)
- **Issues**: [https://github.com/rubydb/rubydb/issues](https://github.com/rubydb/rubydb/issues)
- **Discussions**: [https://github.com/rubydb/rubydb/discussions](https://github.com/rubydb/rubydb/discussions)

---

Made with ❤️ by the RubyDB community

**Status: ALPHA - Not Production Ready**