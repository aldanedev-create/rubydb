# Branching

RubyDB branches represent database snapshots and development lines in the
engine. Create and inspect branches with the CLI, verify the target state, and
retain a backup before merging or checking out a branch containing important
data.

Branch operations are not a substitute for backups or replication. Test branch
diff, merge, checkout, conflict handling, and reopen behavior before using them
in an operational workflow.

## Copy/paste branch workflow

Use a disposable copy while learning the workflow:

```sh
rubydb branch --database tmp/app.rdb --branch-dir tmp/branches --create feature-check --from main
rubydb diff --database tmp/app.rdb --branch-dir tmp/branches --summary main feature-check
```
