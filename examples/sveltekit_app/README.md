# SvelteKit + RubyDB example

This is a small SvelteKit notes app that uses `@dbs/rubydb` in server routes.
The browser never receives database credentials and never opens a RubyDB file.
All data is read and written through a real RubyDB server connection.

## Start RubyDB

From the repository root, in a separate terminal:

```powershell
$env:RUBYDB_PORT = "17438"
$env:RUBYDB_DATA_DIR = "tmp/sveltekit_example_db"
ruby -Ilib examples/server/server.rb
```

## Install and run the app

Build the checked-out Node adapter first:

```powershell
cd adapters/node
npm ci
npm run build
cd ../../examples/sveltekit_app
npm install
$env:RUBYDB_URL = "rubydb://rubydb@127.0.0.1:17438/rubydb"
npm run init-db
npm run dev
```

Open `http://127.0.0.1:5173`. The page can list and create notes.

The example uses `file:../../adapters/node` while developing in this
repository. A deployed application should depend on the published package:

```json
"@dbs/rubydb": "^0.1.0"
```

## Test the real HTTP path

With RubyDB and the SvelteKit dev server running:

```powershell
npm run smoke
```

The smoke test calls `/api/health`, creates a note through `/api/notes`, and
reads it back. It does not use a fake database.

## Production boundary

Use `npm run build` and the SvelteKit production adapter appropriate for your
hosting platform. Set `RUBYDB_URL` only in the server environment, use a
verified `rubydbs://` URL, and run migrations/setup as a release step. Do not
expose the RubyDB URL through public page data or client-side code.

