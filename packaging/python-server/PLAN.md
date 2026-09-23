# Python local runtime implementation plan

The client continues to communicate with RubyDB over its existing protocol.
The optional runtime supplies the same Ruby engine, Ruby interpreter, required
gems, and Go executable in a platform-specific Python wheel.

1. Package the client as `rubydb-python` 0.1.1. Add `local` and `server` extras
   depending on `rubydb-server` 0.1.0 and a lazy command entry point.
2. Build a runtime using an explicit Ruby interpreter. Include the standard
   library, activated runtime gem dependencies, engine source, target Go binary,
   licenses, dependency versions, and SHA-256 inventory. Exclude unrelated gems,
   user credentials, applications, and developer tools.
3. Extract to a versioned user cache and validate hashes. Start from absolute
   executable paths with an isolated Ruby environment. Verify actual Ruby and
   Go execution after relocation before producing a distributable bundle.
4. Add local instance initialization, authenticated loopback connections,
   kernel-selected ports, lifecycle serialization, readiness checks, graceful
   stop, diagnostics, and a URL command. Keep application data outside packages
   and caches so reinstalling a wheel cannot erase the database.
5. Install both wheels in a fresh Python environment. Test real transactions,
   persistence, crash recovery, port conflicts, authentication, multiple data
   directories, startup timeout cleanup, and Go worker startup with host Ruby
   and Go absent from PATH. Fail tests on accidental host Ruby library loading.
6. Build and test Windows x64 first. Each additional platform must produce its
   own relocatable Ruby/dependency bundle and pass the same installed-wheel
   checks. A Go cross-compiled binary alone is insufficient. Do not label an
   ordinary Linux wheel as manylinux without auditing its native dependencies.
7. Publish the validated server wheel and updated client wheel together only
   after reviewing the artifact, package ownership, and target-platform results.
   Client-only installations continue to work on platforms without a runtime
   wheel. Production applications connect to a separately supervised server.

## Acceptance boundary

Local development commands are loopback-only. This package does not create a
managed cloud database, implement an embedded Python engine, or migrate schema
automatically. Runtime updates never start against application data implicitly.
Back up and test an upgrade before restarting a data directory with a new engine.

## Copy/paste packaging check

```sh
python -m build adapters/python
python -m pip install --force-reinstall adapters/python/dist/*.whl
python scripts/verify_python_local.py
```

Run this from a clean virtual environment and verify the installed package can
start its bundled runtime without Ruby or Go on `PATH` before publishing.

## Platform release gates

Windows: ship a RubyInstaller runtime with its DLLs and license notices; test
using Python alone in a relocated environment.

Linux x64/ARM64: build a relocatable Ruby with `--enable-load-relative`, bundle
required non-system shared libraries, and validate in the intended baseline
container without Ruby. Audit for manylinux before a public Linux PyPI wheel.

macOS Intel/Apple Silicon: bundle Ruby and native libraries with relocatable
loader paths; validate on a clean host of each target architecture and inspect
minimum OS compatibility before assigning wheel tags.
