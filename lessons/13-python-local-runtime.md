# Lesson 13: Python-only installation, local development, and production

Python uses the RubyDB network adapter in both environments. For development,
an optional Python wheel supplies a private RubyDB server, Ruby interpreter,
runtime dependencies, and Go worker. For production, your application connects
to a server managed separately from its web workers.

## 1. Install the two local wheels before the PyPI release

Run from the repository root after the maintainer has built the artifacts:

```powershell
python -m venv .venv
.venv/Scripts/python -m pip install --no-index `
  --find-links adapters/python/dist `
  --find-links packaging/python-server/dist `
  "rubydb-python[local]==0.1.1"
```

Only Python is needed on the consuming machine. Copy the two `.whl` files to
another Windows x64 machine, put them in a `wheels` directory, and use:

```powershell
python -m venv .venv
.venv/Scripts/python -m pip install --no-index --find-links wheels "rubydb-python[local]==0.1.1"
```

After these versions are published for your platform, the install becomes:

```powershell
python -m pip install "rubydb-python[local]==0.1.1"
```

The previous client-only 0.1.0 release does not include this capability. The
new extra needs the `rubydb-server` wheel. Do not mistake these commands for
confirmation that a new distribution has been published to PyPI.

## 2. Start a local database

```powershell
.venv/Scripts/python -m rubydb.server start --data-dir .rubydb
.venv/Scripts/python -m rubydb.server status --data-dir .rubydb
$env:RUBYDB_URL = .venv/Scripts/python -m rubydb.server url --data-dir .rubydb
```

The first start extracts and verifies the runtime and can be slower while an
antivirus product scans the bundled Ruby files. The default startup timeout is
180 seconds; for a particularly slow development machine use:

```powershell
.venv/Scripts/python -m rubydb.server start --data-dir .rubydb --timeout 300
```

The port is selected by the operating system and may change after restart.
Use `--port 7432` if you need a fixed port. Each data directory has one owner,
a generated password, and a listener restricted to `127.0.0.1`. `url` includes
that password, so avoid logging it. Put `.rubydb/` in your project's `.gitignore`.

The local CLI works outside PowerShell too. In bash after activating your venv:

```sh
rubydb-python start --data-dir .rubydb
export RUBYDB_URL="$(rubydb-python url --data-dir .rubydb)"
```

Linux/macOS require separately built and validated runtime wheels for those
platforms. A Windows wheel cannot be installed on another OS.

## 3. Save and query data

Save this as `app.py`:

```python
import os
import rubydb

with rubydb.connect(os.environ["RUBYDB_URL"], timeout=5) as db:
    with db.cursor() as cursor:
        cursor.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
        cursor.execute("INSERT INTO notes (title) VALUES (?)", ["My Python app uses RubyDB"])
        cursor.execute("SELECT id, title FROM notes ORDER BY id")
        for note in cursor.fetchall():
            print(note)
```

```powershell
.venv/Scripts/python app.py
```

`with rubydb.connect(...)` commits on successful exit, rolls back on exceptions,
and closes the connection. Parameters use `?`. Repeated runs add another note.
For web applications, initialize schema once in a separate setup step.

## 4. Stop, restart, and inspect

```powershell
.venv/Scripts/python -m rubydb.server doctor --data-dir .rubydb
.venv/Scripts/python -m rubydb.server stop --data-dir .rubydb
.venv/Scripts/python -m rubydb.server start --data-dir .rubydb
$env:RUBYDB_URL = .venv/Scripts/python -m rubydb.server url --data-dir .rubydb
.venv/Scripts/python app.py
```

Existing committed rows survive restart. Data is separate from the installed
wheel and runtime cache. `doctor` verifies cached files and starts the bundled
Go worker to check its protocol. Small queries can still use Ruby under the
normal adaptive policy; Go availability is different from accelerating every
SQL statement.

For errors, inspect `.rubydb/.local/server.log`. Do not remove the database
ownership lock to get around a live owner. A failed start reports a failure;
it does not silently connect to another server.

## 5. Connect the existing Flask or Flaxon examples

Start the local server at the repository root, set `RUBYDB_URL` as above, then
install the framework dependencies inside the same environment:

```powershell
.venv/Scripts/python -m pip install -r examples/python_flask/requirements.txt
.venv/Scripts/python examples/python_flask/init_db.py
.venv/Scripts/python -m flask --app examples/python_flask/app.py run --debug
```

For the exact framework commands and HTTP tests, see the
[Flask example](../examples/python_flask/README.md) and
[Flaxon example](../examples/python_flaxon/README.md). Replace their manual
Ruby server startup with the local package command. The Python adapter makes
synchronous calls; async apps should move database operations to worker threads.

## 6. Production deployment

Install and pin the Python client in the application image:

```sh
python -m pip install rubydb-python==0.1.1
```

Deploy RubyDB as a separate supervised service with a persistent volume. Apply
the [production server lesson](05-rubydb-production-server.md) for the server
configuration, authentication, TLS certificates, monitoring, backups and restore
drills. Those operating requirements still apply to packaged runtimes.

Inject a URL through the platform's secret store, with your actual hostname,
URL-encoded password, and client-side CA certificate path:

```text
RUBYDB_URL=rubydbs://app_rw:URL_ENCODED_PASSWORD@db.internal:7432/app?verify_peer=true&ca_file=%2Fetc%2Frubydb%2Ftls%2Fca.crt
```

The `rubydb.connect(os.environ["RUBYDB_URL"])` code remains the same. Use a
production web server and test the app's queries, transactions and workload.
Do not run `LocalServer.start()` in each web worker. The local CLI provides
development process management; it does not provision production infrastructure.

## 7. Upgrade deliberately

Pin the application client and runtime versions. Stop the local instance and
back up its data before upgrading the server wheel. Check the engine version
reported by `doctor` and run your migration/restore tests before reopening
important databases. If the server becomes unreachable after a write, determine
whether it committed before retrying; use idempotency for externally retried work.
