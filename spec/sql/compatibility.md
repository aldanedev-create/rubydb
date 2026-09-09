# SQL compatibility test contract

This directory contains semantic and syntax references for the documented
RubyDB SQL subset. The executable contract is the integration coverage under
`spec/`, especially the aggregate, join, CTE, subquery, set-operation, upsert,
window, and SQLite profile specs.

A feature is compatible only when parsing, planning, execution, null/type
semantics, errors, transactions, and persistence behavior are validated.
