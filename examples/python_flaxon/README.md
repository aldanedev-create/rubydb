# Flaxon + RubyDB example

This small async Flaxon JSON API stores notes in a real RubyDB server through
the `rubydb-python` DB-API adapter. RubyDB calls are synchronous, so each
database operation is moved to a worker thread with `asyncio.to_thread` and
does not block Flaxon's event loop.

## Run locally

Start RubyDB in another terminal from the repository root:

```powershell
$env:RUBYDB_PORT = "17432"
$env:RUBYDB_DATA_DIR = "tmp/flaxon_example_db"
ruby -Ilib examples/server/server.rb
```

Install this example and initialize its table:

```powershell
cd examples/python_flaxon
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:17432/rubydb"
python init_db.py
flaxon run app:app --reload
```

Try it:

```powershell
Invoke-RestMethod http://127.0.0.1:8000/rubydb-health
Invoke-RestMethod http://127.0.0.1:8000/notes
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8000/notes `
  -ContentType application/json -Body '{"title":"ship the service"}'
```

For production, run without `--reload`, use `rubydbs://` with peer
verification, place credentials in a secret manager, and run Flaxon behind
TLS and a reverse proxy. Use shared infrastructure for state that must be
visible across multiple application workers.

## Test against a live RubyDB server

With `RUBYDB_URL` set and RubyDB running:

```powershell
python init_db.py
python -m unittest -v
```
