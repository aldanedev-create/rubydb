# RubyDB production journey

This ten-lesson journey teaches a practical way to use RubyDB without
pretending it is a universal PostgreSQL replacement. It is written for a
newcomer who wants copy-and-paste commands, but it ends with the operational
habits expected of a production team.

## The decision in one picture

```text
Browser / API clients
          |
       Rails app  --------------------> PostgreSQL
          |                              system of record for a large app
          |
          +---------------------------> RubyDB server
                                         bounded internal microservice

RubyDB embedded = one owning Ruby process and one local persistent path.
```

Use PostgreSQL when the application needs a broadly supported shared database,
many application instances, managed high availability, large connection and
query ecosystems, or PostgreSQL-specific SQL and extensions. Use RubyDB
embedded for local development, tests, tools, and a deliberately single-owner
workload. Use RubyDB server/client for a bounded service whose workload fits
RubyDB's documented SQL and operational surface.

RubyDB is currently alpha software. This guide is a deployment and learning
path, not a certification that every Rails query, SQL dialect feature, or
failure mode is supported. Test the exact application and keep PostgreSQL as
the safer default for a large public system until your evidence says otherwise.

## The ten checkpoints

1. [Foundations and database boundaries](01-foundations.md)
2. [Local development](02-local-development.md)
3. [RubyDB embedded mode](03-embedded-rubydb.md)
4. [Rails and complex application code](04-rails-complex-apps.md)
5. [RubyDB server production setup](05-rubydb-production-server.md)
6. [PostgreSQL for large applications](06-postgresql-massive-apps.md)
7. [A hybrid microservice architecture](07-hybrid-microservices.md)
8. [Migrations, backups, and recovery](08-migrations-backups-recovery.md)
9. [Observability, security, and scale](09-observability-security-scale.md)
10. [Release readiness](10-release-readiness.md)

## Prerequisites

Install a supported Ruby version, Git, and Bundler. From a clone of this
repository:

```sh
git clone https://github.com/aldanedev-create/rubydb.git
cd rubydb
bundle install
bundle exec rspec
```

The test suite is useful evidence about the repository, but it is not evidence
about your application. Later lessons add application queries, restore drills,
and deployment checks.

## Checkpoint

Before continuing, write down these three answers in your project runbook:

* Which database owns business-critical data?
* How many processes and hosts will connect to it?
* What recovery point objective (RPO) and recovery time objective (RTO) must be
  met?

If the answers are unknown, the application is not ready for a production
database choice. Continue to lesson 2 to build a reproducible local baseline.
