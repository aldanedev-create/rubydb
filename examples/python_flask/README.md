# Flask + RubyDB example

This small Flask JSON API stores notes in a real RubyDB server through the
`rubydb-python` DB-API adapter. It does not use SQLite, an in-memory fake, or
direct access to an embedded `.rdb` file.

## Run locally

Start RubyDB in another terminal from the repository root:

```powershell
$env:RUBYDB_PORT = "17432"
$env:RUBYDB_DATA_DIR = "tmp/flask_example_db"
ruby -Ilib examples/server/server.rb
```

Install this example and initialize its table:

```powershell
cd examples/python_flask
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:17432/rubydb"
python init_db.py
flask --app app run --debug
```

Try it:

```powershell
Invoke-RestMethod http://127.0.0.1:5000/health
Invoke-RestMethod http://127.0.0.1:5000/notes
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:5000/notes `
  -ContentType application/json -Body '{"title":"ship the service"}'
```

For production, do not use Flask's development server or `--debug`. Run the
application behind a process manager and reverse proxy, use a verified
`rubydbs://` endpoint, and keep credentials in a secret manager.

## Test against a live RubyDB server

With `RUBYDB_URL` set and RubyDB running:

```powershell
python init_db.py
python -m unittest -v
```

