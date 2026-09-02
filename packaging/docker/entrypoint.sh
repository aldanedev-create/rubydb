#!/bin/sh
set -eu

: "${RUBYDB_DATA_DIR:=/var/lib/rubydb/data}"
: "${RUBYDB_LOG_DIR:=/var/log/rubydb}"
: "${RUBYDB_PID_FILE:=/run/rubydb.pid}"
: "${RUBYDB_HOST:=0.0.0.0}"
: "${RUBYDB_PORT:=7432}"

exec rubydb start \
  --host "$RUBYDB_HOST" \
  --port "$RUBYDB_PORT" \
  --data-dir "$RUBYDB_DATA_DIR" \
  --log-dir "$RUBYDB_LOG_DIR" \
  --pid-file "$RUBYDB_PID_FILE"
