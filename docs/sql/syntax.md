# SQL syntax

Statements are parsed by RubyDB's lexer and parser and executed through the
planner. The supported statements include `SELECT`, `INSERT`, `UPDATE`,
`DELETE`, table/index/schema/view DDL, transactions/savepoints, `EXPLAIN`, and
`VACUUM` as listed in [compatibility](compatibility.md).

Use semicolons for multiple statements only where the client path supports
them. Identifiers may be quoted with double quotes or backticks. Unsupported
syntax fails with a parser or execution error; it is never silently ignored.
