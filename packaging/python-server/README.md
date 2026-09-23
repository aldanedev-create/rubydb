# RubyDB local server for Python

This optional distribution bundles the Ruby interpreter, RubyDB engine and
runtime gems, and Go accelerator. Application developers need Python; they do
not need Ruby, RubyGems, Go, Docker, or an internet download at server startup.
The engine runs in a separate local process. Python connects using the existing
RubyDB DB-API adapter.

## Install and start

After both new distributions are published for your platform:

```sh
python -m pip install "rubydb-python[local]==0.1.1"
rubydb-python start --data-dir .rubydb
rubydb-python status --data-dir .rubydb
rubydb-python doctor --data-dir .rubydb
```

`rubydb-python[server]` is an alias for the same extra. `python -m rubydb.server`
and `rubydb-server` expose the same commands. `start` initializes automatically;
`init` can also be used before starting. With no `--port`, the OS assigns an
available port. To request a fixed port, add `--port 7432`; a conflict fails
without connecting to a different service.

The first start extracts and verifies the bundled runtime. On a cold Windows
machine, antivirus scanning can make that start slower than later starts, so the
default readiness timeout is 180 seconds. Override it explicitly when needed:

```powershell
rubydb-python start --data-dir .rubydb --timeout 300
```

On Windows PowerShell:

```powershell
$env:RUBYDB_URL = rubydb-python url --data-dir .rubydb
python app.py
```

On Linux/macOS:

```sh
export RUBYDB_URL="$(rubydb-python url --data-dir .rubydb)"
python app.py
```

The URL contains generated credentials. Keep it private. `status` and `start`
do not print the password. Add `.rubydb/` and `.env` to your application's
`.gitignore`; the data directory's `.local/config.json` contains credentials.
Use a data directory accessible only to your OS account (private ACLs on Windows).

```python
import os
import rubydb

with rubydb.connect(os.environ["RUBYDB_URL"], timeout=5) as db:
    with db.cursor() as cursor:
        cursor.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
        cursor.execute("INSERT INTO notes (title) VALUES (?)", ["Hello from Python"])
        cursor.execute("SELECT id, title FROM notes ORDER BY id")
        print(cursor.fetchall())
```

The connection context commits on normal exit, rolls back on an exception, and
closes the connection. Prefer one-time schema setup over creating tables in each
web request. Use `?` parameters for values.

```sh
rubydb-python stop --data-dir .rubydb
```

Stop requests an orderly server shutdown and keeps all database files. Starting
again reopens the same database. Start is idempotent for a healthy instance with
the same data directory. Different directories receive independent servers and
ports. An unhealthy live owner must be diagnosed before starting another owner.

## Python API

```python
import rubydb
from rubydb_server import LocalServer

server = LocalServer(".rubydb")
server.start()
try:
    with rubydb.connect(server.url) as db:
        with db.cursor() as cursor:
            cursor.execute("SELECT 1")
            print(cursor.fetchone())
finally:
    server.stop()
```

The caller explicitly controls the server lifetime. Importing the package or
opening a network connection never auto-starts a second database process.

## What is installed

`rubydb-python` is a small Python client. `rubydb-server` contains a
platform-specific compressed runtime. First start extracts it to
`~/.cache/rubydb/<bundle-sha256>` (override with `RUBYDB_RUNTIME_CACHE`). It verifies
the archive and cached file inventory and restores executable permissions.
This checksum detects corruption; publisher identity still depends on how the
wheel was obtained. Runtime dependencies and license notices are inside the
bundle. Data and credentials live in the explicitly chosen data directory.

`doctor` exercises the real Ruby engine and requires a successful Go worker
response. Queries use RubyDB's normal automatic accelerator selection; small
queries may execute in Ruby. Installing this package does not guarantee any
particular query speedup.

## Build and test as a maintainer

On a Windows x64 builder with RubyDB's gem dependencies installed:

```powershell
python -m pip install build twine
python scripts/build_python_server.py --ruby C:/Ruby40-x64/bin/ruby.exe
python -m build --wheel adapters/python
python -m build --wheel packaging/python-server
python -m twine check adapters/python/dist/*.whl packaging/python-server/dist/*.whl
python -m venv tmp/python-local-check
tmp/python-local-check/Scripts/python -m pip install --no-index `
  --find-links adapters/python/dist --find-links packaging/python-server/dist `
  "rubydb-python[local]==0.1.1"
$env:RUBYDB_LOCAL_LIVE = "1"
tmp/python-local-check/Scripts/python -m unittest discover -s packaging/python-server/tests -v
```

The bundle builder copies only activated gem dependencies and the Ruby standard
library. It relocates and executes Ruby/Go and rejects Ruby libraries loaded from
outside the bundle. Use a clean dedicated build machine for release provenance.
The binary wheel is `py3-none-<platform>`, not `py3-none-any`.

Other OS/architecture builds require a relocatable Ruby prefix and target-native
dependencies, plus the same installed-wheel tests. The builder supports matching
Windows, Linux, and macOS hosts; only platforms with completed validation should
be advertised or published. Linux wheels need a separate native-library audit
before being labeled manylinux. See `PLAN.md` for release gates.

Never publish a source-only `rubydb-server` distribution that silently compiles
Ruby on the user's machine. Publish tested wheels, then the updated client wheel.
Package availability on PyPI is a separate release step.

For the initial Windows x64 release, validate the exact two wheels and publish:

```powershell
python scripts/release_python_local.py
python scripts/release_python_local.py --publish
```

Validation installs both wheels into a temporary Python environment and runs
the real server tests with Ruby/Go removed from PATH. It records artifact
SHA-256 hashes. Publishing refuses altered or unvalidated artifacts, checks
metadata again, and uploads only the new client and server wheels. It does not
include old 0.1.0 client files that may remain in `dist`.

Create/manage your PyPI token at <https://pypi.org/manage/account/token/>. Use
Twine's terminal prompt/keyring or protected `TWINE_USERNAME=__token__` and
`TWINE_PASSWORD` environment settings; never commit or share the token.
The first server upload creates a separate `rubydb-server` project if PyPI
accepts that project name and your account has permission. Subsequent releases
can use project-scoped tokens or Trusted Publishing for each project.

## Production and upgrades

For a production Python web app, install `rubydb-python` and inject the URL of
a separately supervised RubyDB server using verified TLS. The local launcher
deliberately binds to `127.0.0.1`; it is not a production TLS/service manager.
Do not invoke local `start` from each Gunicorn, Flask, or Flaxon worker.

Pin client and server versions. Stop the local server before upgrading its
runtime package. Back up the data and test restore/upgrade compatibility before
reopening it with a different RubyDB engine. The package never deletes data,
automatically migrates schemas, or upgrades a running server.

## Troubleshooting

- `Local runtime missing`: install the `[local]` extra or both locally built wheels.
- `No matching distribution`: no wheel exists for this Python/OS/architecture;
  use the client with an external server until that platform is released.
- Startup failure: inspect `<data-dir>/.local/server.log`. The child may have
  failed to bind, load a dependency, acquire the database lock, or recover data.
- Port conflict: omit `--port` or choose another port. Use `url` after startup.
- Lifecycle command busy: another start/stop is in progress; retry after it ends.
- Unhealthy live instance: inspect logs and stop gracefully. Do not delete the
  database lock or launch another server against the same directory.
- Checksum mismatch: reinstall a verified wheel and use a new runtime cache;
  keep the database directory intact. Do not bypass integrity validation.
- Timeout during stop: inspect the process and log. The CLI never kills an
  unrelated process using a stale PID; forced termination requires operator action.
- Connection refused after restart: refresh `RUBYDB_URL`; automatically selected
  ports may change between runs. Your database files remain in the same place.
