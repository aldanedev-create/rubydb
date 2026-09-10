# Lesson 10: release readiness

The final checkpoint is evidence, not optimism. A production release should
identify the exact RubyDB and adapter versions, supported Ruby/Rails/OS matrix,
tested SQL surface, backup artifact, restore result, load baseline, security
review, and rollback owner.

## Run repository checks

From the RubyDB repository:

```sh
bundle install
bundle exec rspec
bundle exec rake
git diff --check
```

Run the Rails adapter suite from its directory and repeat it for every Rails
and Ruby version you claim to support:

```sh
cd adapters/activerecord
bundle install
bundle exec rspec
```

Add your application’s complex query, migration, schema dump/load, concurrency,
and failure tests to CI. A passing library suite does not certify an arbitrary
application.

## Release a gem safely

Review the project’s release instructions and run the preflight with a version
that has not already been published:

```sh
RUBYDB_RELEASE_VERSION=0.1.5 ruby scripts/release
```

On PowerShell, use:

```powershell
$env:RUBYDB_RELEASE_VERSION = "0.1.5"
ruby scripts/release
```

The release script builds the gem and writes a checksum. Check the artifact
locally before publishing:

```sh
gem specification pkg/rubydb-0.1.5.gem
gem install pkg/rubydb-0.1.5.gem --local
ruby -rrubydb -e 'puts RubyDB::VERSION'
```

Publishing requires a RubyGems API key or trusted publishing setup configured
on the release machine. The local script publishes only when both the explicit
publish flag and secret are present; never commit the secret:

```sh
RUBYDB_RELEASE_VERSION=0.1.5 \
RUBYDB_PUBLISH=1 \
GEM_HOST_API_KEY="YOUR_RUBYGEMS_API_KEY" \
ruby scripts/release
```

On Windows PowerShell:

```powershell
$env:RUBYDB_RELEASE_VERSION = "0.1.5"
$env:RUBYDB_PUBLISH = "1"
$env:GEM_HOST_API_KEY = "YOUR_RUBYGEMS_API_KEY"
ruby scripts/release
```

Prefer the repository’s signed GitHub Actions release workflow for a public
release. Store signing keys and RubyGems secrets only in protected secret
storage; do not put them in the repository or a checked-in `.env` file.

Release the adapter separately when its version changes, update the changelog,
tag the source commit, and publish the checksums and supported-version notes.

## Publish the Python adapter to PyPI

The Python adapter is a separate distribution named `rubydb-python`; publishing
the Ruby gem does not publish this package. Build it from the adapter directory
and validate both distribution formats before upload:

```powershell
cd adapters/python
python -m pip install --upgrade build twine
python -m build
python -m twine check dist/*
```

Prefer PyPI Trusted Publishing from CI. For a local upload, use a short-lived,
scope-limited PyPI token through the environment or Twine's prompt. Never
commit a token:

```powershell
$env:TWINE_USERNAME = "__token__"
$env:TWINE_PASSWORD = (Get-Clipboard).Trim()
python -m twine upload dist/*
Remove-Item Env:TWINE_PASSWORD
```

After upload, verify the package from a clean environment and run the live
adapter tests against a RubyDB server:

```powershell
python -m venv .venv-clean
.venv-clean\Scripts\Activate.ps1
python -m pip install rubydb-python
$env:RUBYDB_URL = "rubydbs://service_user:password@127.0.0.1:7432/rubydb"
python -m unittest discover -s adapters/python/tests -v
```

The package provides DB-API 2.0 access to RubyDB server mode. It is not a
PostgreSQL driver and does not make PostgreSQL SQL portable to RubyDB. Pin the
adapter and server versions together, use TLS in production, and keep the
application's migration and rollback procedure under version control.

## Build and publish the Node adapter

The Node adapter is a separate public npm package named `rubydb-node`. The
literal `node/rubydb` is not a valid npm name because npm reserves `/` for
scoped packages such as `@scope/package`.

```powershell
cd adapters/rubydb
npm ci
npm test
npm run publish:check
npm publish --access public
```

Use npm Trusted Publishing from CI or a protected npm token. Never commit an
`.npmrc` containing credentials. The package's live test runs against a real
RubyDB server when `RUBYDB_URL` is set:

```powershell
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb"
npm test
```

The package is a Node.js/TypeScript RubyDB client, not a PostgreSQL driver. Pin
the npm client and RubyDB server versions together and validate the target
application's SQL, retry, TLS, migration, backup, and failover behavior.

## Deployment gate

For a direct RubyDB production deployment, follow [lesson 5](05-rubydb-production-server.md)
from top to bottom before this gate. For a massive Rails application, follow
[lesson 6](06-postgresql-massive-apps.md) and keep RubyDB at a separate service
boundary.

Do not promote until all of these have an owner and a recorded result:

* application tests pass against the production database topology;
* migrations pass on empty and populated staging data;
* a verified backup restores on another path or host;
* load tests cover concurrency, timeouts, cancellation, and resource limits;
* multi-process client/server tests cover restart and network failure;
* failover and fencing behavior is validated if high availability is claimed;
* TLS, secrets, least privilege, certificate rotation, and audit logging are
  reviewed;
* dashboards and alerts page an on-call person;
* rollback, upgrade, and data-reconciliation procedures are rehearsed; and
* the README and compatibility guide state what is supported and what is not.

## A sensible first production architecture

For a large Rails product, use managed PostgreSQL for the main application and
deploy RubyDB only for an independently owned microservice whose workload has
passed the lessons above. For a small internal or single-owner service, RubyDB
server mode can be reasonable when its SQL, concurrency, recovery, and
operational limits are accepted. Do not call either architecture universally
compatible without workload evidence.

## Final checkpoint

The journey is complete when a new operator can deploy the exact release,
verify a real query, observe health and capacity, restore data, and explain the
rollback path without relying on the author’s laptop. Keep the evidence with
the release and repeat the drills after major RubyDB, Rails, schema, or hosting
changes.

Continue using the repository’s [CLI guide](../docs/cli.md), [production
operations guide](../docs/operations/production-guide.md), [Rails compatibility
guide](../docs/rails/compatibility-guide.md), and [SQL compatibility
guide](../docs/sql/compatibility-guide.md) as the detailed references.
