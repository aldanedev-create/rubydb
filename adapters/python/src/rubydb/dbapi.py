"""A small, dependency-free Python DB-API 2.0 client for RubyDB.

The adapter intentionally uses RubyDB server mode. It never opens an embedded
``.rdb`` file. The wire protocol is newline-delimited JSON with a handshake,
authentication, capability negotiation, and request-scoped query messages.
"""

from __future__ import annotations

import datetime as _datetime
import decimal as _decimal
import json
import queue
import socket
import ssl
import threading
import time
import uuid
from contextlib import contextmanager
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
from urllib.parse import parse_qs, unquote, urlsplit


apilevel = "2.0"
threadsafety = 2
paramstyle = "qmark"


class Warning(Exception):
    """The DB-API warning base class."""


class Error(Exception):
    """The DB-API error base class."""


class InterfaceError(Error):
    """The client was used incorrectly or the connection is closed."""


class DatabaseError(Error):
    """An error reported by RubyDB or the database connection."""


class DataError(DatabaseError):
    """An invalid value was rejected by the database."""


class OperationalError(DatabaseError):
    """A network, timeout, authentication, or server availability error."""


class IntegrityError(DatabaseError):
    """A constraint or integrity error."""


class InternalError(DatabaseError):
    """An internal database error."""


class ProgrammingError(DatabaseError):
    """Invalid SQL or an invalid statement operation."""


class NotSupportedError(DatabaseError):
    """A requested DB-API feature is not supported."""


ErrorTuple = Tuple[str, Optional[str], Optional[int], Optional[int], Optional[str], Optional[str], Optional[str]]


def _truthy(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _timestamp() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def _json_value(value: Any) -> Any:
    """Convert common DB-API values to JSON without losing booleans/nulls."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, (_datetime.datetime, _datetime.date, _datetime.time)):
        return value.isoformat()
    if isinstance(value, _decimal.Decimal):
        return str(value)
    if isinstance(value, (bytes, bytearray, memoryview)):
        # RubyDB's JSON protocol has no binary scalar marker; preserve bytes as
        # UTF-8 when possible and fail clearly for arbitrary binary data.
        try:
            return bytes(value).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise DataError("binary parameters must be UTF-8 for JSON transport") from exc
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    raise DataError("unsupported parameter type: %s" % type(value).__name__)


def _message(message_type: str, payload: Optional[Dict[str, Any]] = None, message_id: Optional[str] = None) -> Dict[str, Any]:
    return {
        "type": message_type,
        "id": message_id or "msg_%s" % uuid.uuid4().hex,
        "created_at": _timestamp(),
        "payload": payload or {},
        "compressed": False,
        "encrypted": False,
        "checksum": None,
    }


def _parse_url(url: str, options: Dict[str, Any]) -> Dict[str, Any]:
    parsed = urlsplit(url)
    if parsed.scheme not in {"rubydb", "rubydbs"}:
        raise InterfaceError("RubyDB URLs must use rubydb:// or rubydbs://")
    if not parsed.hostname:
        raise InterfaceError("RubyDB URL must include a host")

    query = parse_qs(parsed.query, keep_blank_values=True)

    def query_value(name: str, default: Any = None) -> Any:
        values = query.get(name)
        return values[-1] if values else default

    config: Dict[str, Any] = {
        "host": parsed.hostname,
        "port": parsed.port or 7432,
        "username": unquote(parsed.username) if parsed.username else "rubydb",
        "password": unquote(parsed.password) if parsed.password else "",
        "database": unquote(parsed.path.lstrip("/")) or "rubydb",
        "ssl": parsed.scheme == "rubydbs",
    }
    for key in ("timeout", "max_frame_size", "pool_size"):
        value = query_value(key)
        if value is not None:
            config[key] = float(value) if key == "timeout" else int(value)
    for key in ("verify_peer", "compress"):
        value = query_value(key)
        if value is not None:
            config[key] = _truthy(value)
    for key in ("ca_file", "cert_file", "key_file", "min_version", "format"):
        value = query_value(key)
        if value is not None:
            config[key] = unquote(value)
    config.update(options)
    return config


def _error_for(message: str) -> DatabaseError:
    lowered = message.lower()
    if any(word in lowered for word in ("unique", "constraint", "foreign key", "not null")):
        return IntegrityError(message)
    if any(word in lowered for word in ("syntax", "parse", "statement not found", "unknown request")):
        return ProgrammingError(message)
    if any(word in lowered for word in ("timeout", "timed out", "connection", "authentication", "server closed")):
        return OperationalError(message)
    return DatabaseError(message)


class _WireConnection:
    """One serialized request/response connection to a RubyDB server."""

    PROTOCOL_VERSION = 0x010000

    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.socket: Optional[socket.socket] = None
        self.reader = None
        self.lock = threading.RLock()
        self.closed = True
        self.max_frame_size = int(config.get("max_frame_size", 10 * 1024 * 1024))
        self.request_timeout = float(config.get("timeout", 30))

    def connect(self) -> None:
        with self.lock:
            if not self.closed:
                return
            try:
                raw = socket.create_connection(
                    (self.config["host"], int(self.config["port"])),
                    timeout=self.request_timeout,
                )
                if self.config.get("ssl"):
                    verify_peer = _truthy(self.config.get("verify_peer"), True)
                    if verify_peer:
                        context = ssl.create_default_context(cafile=self.config.get("ca_file"))
                        context.check_hostname = True
                    else:
                        context = ssl._create_unverified_context()
                    if self.config.get("cert_file"):
                        context.load_cert_chain(self.config["cert_file"], self.config.get("key_file"))
                    raw = context.wrap_socket(raw, server_hostname=self.config["host"])
                self.socket = raw
                self.socket.settimeout(self.request_timeout)
                self.reader = self.socket.makefile("rb")
                self.closed = False
                self._handshake()
            except (OSError, ssl.SSLError, Error):
                self._close_unlocked()
                raise
            except Exception as exc:
                self._close_unlocked()
                raise OperationalError("connection failed: %s" % exc) from exc

    def close(self) -> None:
        with self.lock:
            self._close_unlocked()

    def _close_unlocked(self) -> None:
        self.closed = True
        if self.reader is not None:
            try:
                self.reader.close()
            except OSError:
                pass
        if self.socket is not None:
            try:
                self.socket.close()
            except OSError:
                pass
        self.reader = None
        self.socket = None

    def _write(self, message: Dict[str, Any]) -> None:
        if self.socket is None or self.closed:
            raise InterfaceError("RubyDB connection is closed")
        encoded = (json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        if len(encoded) > self.max_frame_size:
            raise DataError("RubyDB request exceeds max_frame_size")
        try:
            self.socket.sendall(encoded)
        except (OSError, ssl.SSLError) as exc:
            self._close_unlocked()
            raise OperationalError("send failed: %s" % exc) from exc

    def _read(self, timeout: Optional[float] = None) -> Dict[str, Any]:
        if self.socket is None or self.reader is None or self.closed:
            raise InterfaceError("RubyDB connection is closed")
        self.socket.settimeout(self.request_timeout if timeout is None else max(float(timeout), 0.001))
        try:
            frame = self.reader.readline(self.max_frame_size + 1)
            if not frame:
                self._close_unlocked()
                raise OperationalError("server closed connection")
            if len(frame) > self.max_frame_size or not frame.endswith(b"\n"):
                self._close_unlocked()
                raise OperationalError("RubyDB response frame exceeds max_frame_size")
            value = json.loads(frame.decode("utf-8"))
            if not isinstance(value, dict):
                raise OperationalError("invalid RubyDB response frame")
            return value
        except socket.timeout as exc:
            raise exc
        except (OSError, ssl.SSLError, UnicodeError, json.JSONDecodeError) as exc:
            self._close_unlocked()
            raise OperationalError("receive failed: %s" % exc) from exc

    def _handshake(self) -> None:
        self._write(_message("handshake", {
            "protocol_version": self.PROTOCOL_VERSION,
            "client_name": "rubydb-python",
            "client_version": "0.1.0",
            "username": self.config.get("username"),
            "database": self.config.get("database"),
        }))
        response = self._read()
        payload = response.get("payload") or {}
        if response.get("type") != "handshake_response" or payload.get("success") is False:
            raise OperationalError("handshake failed: %s" % payload.get("error", "unexpected response"))

        self._write(_message("authentication_response", {
            "username": self.config.get("username", "rubydb"),
            "password": self.config.get("password", ""),
            "database": self.config.get("database", "rubydb"),
            "auth_method": "password" if self.config.get("password") else "none",
        }))
        auth = self._read()
        auth_payload = auth.get("payload") or {}
        if auth.get("type") != "authentication" or auth_payload.get("success") is False:
            raise OperationalError("authentication failed: %s" % auth_payload.get("error", "rejected"))

        self._write(_message("synchronize", {
            "supported": 0,
            "enabled": 0,
            "negotiated": 0,
            "features": {},
            "limits": {"batch_size": 100, "timeout": 30, "max_rows": 10000},
            "compression": False,
            "encryption": False,
            "pipeline": False,
            "batch_size": 100,
            "timeout": int(self.request_timeout),
            "max_rows": 10000,
        }))
        ready = self._read()
        if ready.get("type") != "ready_for_query" or (ready.get("payload") or {}).get("success") is False:
            raise OperationalError("protocol synchronization failed")

    def request(self, message_type: str, payload: Optional[Dict[str, Any]] = None, timeout: Optional[float] = None) -> Dict[str, Any]:
        with self.lock:
            if self.closed:
                self.connect()
            request_id = "msg_%s" % uuid.uuid4().hex
            self._write(_message(message_type, payload or {}, request_id))
            try:
                return self._read(timeout)
            except socket.timeout as exc:
                self._cancel_after_timeout(request_id)
                raise OperationalError("RubyDB request timed out and cancellation was sent") from exc

    def _cancel_after_timeout(self, request_id: str) -> None:
        """Send wire cancellation and drain the matching response if possible."""
        try:
            self.socket.settimeout(2.0)  # type: ignore[union-attr]
            self._write(_message("cancel", {"target_request_id": request_id}))
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline:
                remaining = max(deadline - time.monotonic(), 0.05)
                response = self._read(remaining)
                payload = response.get("payload") or {}
                if payload.get("request_id") == request_id:
                    return
                if payload.get("target_request_id") == request_id:
                    continue
        except Exception:
            self._close_unlocked()


class Connection:
    """PEP 249 connection backed by one RubyDB server session."""

    def __init__(self, config: Dict[str, Any]):
        self._wire = _WireConnection(config)
        self._closed = False
        self._autocommit = bool(config.get("autocommit", False))
        self._in_transaction = False
        self._lock = threading.RLock()
        self._wire.connect()

    @property
    def closed(self) -> bool:
        return self._closed or self._wire.closed

    @property
    def autocommit(self) -> bool:
        return self._autocommit

    @autocommit.setter
    def autocommit(self, value: bool) -> None:
        with self._lock:
            self._ensure_open()
            value = bool(value)
            if value and self._in_transaction:
                self.commit()
            self._autocommit = value

    def cursor(self) -> "Cursor":
        self._ensure_open()
        return Cursor(self)

    def execute(self, operation: str, parameters: Optional[Sequence[Any]] = None, timeout: Optional[float] = None) -> "Cursor":
        cursor = self.cursor()
        cursor.execute(operation, parameters, timeout=timeout)
        return cursor

    def prepare(self, operation: str) -> "PreparedStatement":
        """Prepare SQL on the current RubyDB session."""
        with self._lock:
            self._ensure_open()
            if not isinstance(operation, str) or not operation.strip():
                raise ProgrammingError("operation must be a non-empty SQL string")
            response = self._wire.request("prepare", {"sql": operation})
            payload = response.get("payload") or {}
            if payload.get("success") is False:
                raise _error_for(str(payload.get("error", "prepare failed")))
            statement_id = payload.get("statement_id") or (payload.get("data") or {}).get("statement_id")
            if not statement_id:
                raise DatabaseError("RubyDB prepare response did not include statement_id")
            return PreparedStatement(self, operation, str(statement_id))

    def commit(self) -> None:
        with self._lock:
            self._ensure_open()
            if self._in_transaction:
                self._response("commit")
                self._in_transaction = False

    def rollback(self) -> None:
        with self._lock:
            self._ensure_open()
            if self._in_transaction:
                self._response("rollback")
                self._in_transaction = False

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            try:
                if self._in_transaction:
                    try:
                        self.rollback()
                    except Error:
                        # close() is a best-effort resource release; the
                        # original connection failure must not be hidden.
                        pass
            finally:
                self._wire.close()
                self._closed = True
                self._in_transaction = False

    def ping(self) -> bool:
        self._ensure_open()
        self._response("ping")
        return True

    def _ensure_open(self) -> None:
        if self.closed:
            raise InterfaceError("RubyDB connection is closed")

    def _begin_if_needed(self, operation: str) -> None:
        if self._autocommit or self._in_transaction:
            return
        keyword = operation.lstrip().split(None, 1)[0].lower() if operation.strip() else ""
        if keyword not in {"begin", "commit", "rollback"}:
            self._response("begin")
            self._in_transaction = True

    def _execute(self, operation: str, parameters: Sequence[Any], timeout: Optional[float]) -> Dict[str, Any]:
        with self._lock:
            self._ensure_open()
            self._begin_if_needed(operation)
            payload = {
                "sql": operation,
                "params": [_json_value(value) for value in parameters],
            }
            if timeout is not None:
                payload["deadline_at"] = (
                    _datetime.datetime.now(_datetime.timezone.utc) + _datetime.timedelta(seconds=float(timeout))
                ).isoformat().replace("+00:00", "Z")
            return self._unwrap(self._wire.request("query", payload, timeout=timeout))

    def _execute_prepared(self, statement: "PreparedStatement", parameters: Sequence[Any], timeout: Optional[float]) -> Dict[str, Any]:
        with self._lock:
            self._ensure_open()
            self._begin_if_needed(statement.operation)
            payload = {
                "statement_id": statement.statement_id,
                "params": [_json_value(value) for value in parameters],
            }
            if timeout is not None:
                payload["deadline_at"] = (
                    _datetime.datetime.now(_datetime.timezone.utc) + _datetime.timedelta(seconds=float(timeout))
                ).isoformat().replace("+00:00", "Z")
            return self._unwrap(self._wire.request("execute", payload, timeout=timeout))

    def _response(self, operation: str) -> Dict[str, Any]:
        return self._unwrap(self._wire.request(operation, {}))

    @staticmethod
    def _unwrap(envelope: Dict[str, Any]) -> Dict[str, Any]:
        payload = envelope.get("payload") or {}
        if payload.get("success") is False:
            raise _error_for(str(payload.get("error", "RubyDB request failed")))
        if isinstance(payload.get("result"), dict):
            result = dict(payload["result"])
        elif isinstance(payload.get("data"), dict):
            result = dict(payload["data"])
        else:
            result = dict(payload)
        result.setdefault("success", True)
        return result

    def __enter__(self) -> "Connection":
        self._ensure_open()
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        try:
            if exc_type:
                self.rollback()
            else:
                self.commit()
        finally:
            self.close()


class Cursor:
    """PEP 249 cursor for RubyDB query results."""

    def __init__(self, connection: Connection):
        self.connection = connection
        self.arraysize = 1
        self.description: Optional[List[ErrorTuple]] = None
        self.rowcount = -1
        self.lastrowid = None
        self._rows: List[Any] = []
        self._position = 0
        self._closed = False

    def execute(self, operation: str, parameters: Optional[Sequence[Any]] = None, timeout: Optional[float] = None) -> "Cursor":
        self._ensure_open()
        if not isinstance(operation, str) or not operation.strip():
            raise ProgrammingError("operation must be a non-empty SQL string")
        values = [] if parameters is None else list(parameters)
        result = self.connection._execute(operation, values, timeout)
        self._load_result(result)
        return self

    def executemany(self, operation: str, seq_of_parameters: Iterable[Sequence[Any]]) -> "Cursor":
        self._ensure_open()
        total = 0
        last = None
        for parameters in seq_of_parameters:
            last = self.execute(operation, parameters)
            if self.rowcount >= 0:
                total += self.rowcount
        if last is not None:
            self.rowcount = total
        return self

    def fetchone(self) -> Optional[Any]:
        self._ensure_open()
        if self._position >= len(self._rows):
            return None
        row = self._rows[self._position]
        self._position += 1
        return row

    def fetchmany(self, size: Optional[int] = None) -> List[Any]:
        self._ensure_open()
        amount = self.arraysize if size is None else int(size)
        if amount < 0:
            raise ProgrammingError("fetch size cannot be negative")
        rows = self._rows[self._position:self._position + amount]
        self._position += len(rows)
        return rows

    def fetchall(self) -> List[Any]:
        self._ensure_open()
        rows = self._rows[self._position:]
        self._position = len(self._rows)
        return rows

    def close(self) -> None:
        self._closed = True
        self._rows = []

    def setinputsizes(self, sizes: Any) -> None:
        return None

    def setoutputsize(self, size: int, column: Optional[int] = None) -> None:
        return None

    def __iter__(self):
        self._ensure_open()
        return self

    def __next__(self):
        row = self.fetchone()
        if row is None:
            raise StopIteration
        return row

    def _load_result(self, result: Dict[str, Any]) -> None:
        self._rows = list(result.get("rows") or [])
        self._position = 0
        columns = result.get("columns") or []
        self.description = []
        for column in columns:
            if isinstance(column, dict):
                name = column.get("name") or column.get("column")
                type_code = column.get("type")
            else:
                name = str(column)
                type_code = None
            self.description.append((name, type_code, None, None, None, None, None))
        if not self.description and self._rows and isinstance(self._rows[0], dict):
            self.description = [(str(name), None, None, None, None, None, None) for name in self._rows[0]]
        self.rowcount = int(result.get("affected_rows", len(self._rows)))
        self.lastrowid = result.get("inserted_id", result.get("row_id"))

    def _ensure_open(self) -> None:
        if self._closed:
            raise InterfaceError("cursor is closed")

    def __enter__(self) -> "Cursor":
        self._ensure_open()
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        self.close()


class PreparedStatement:
    """A server-side prepared statement."""

    def __init__(self, connection: Connection, operation: str, statement_id: str):
        self.connection = connection
        self.operation = operation
        self.statement_id = statement_id
        self._closed = False

    def execute(self, parameters: Optional[Sequence[Any]] = None, timeout: Optional[float] = None) -> Cursor:
        if self._closed:
            raise InterfaceError("prepared statement is closed")
        cursor = self.connection.cursor()
        result = self.connection._execute_prepared(self, [] if parameters is None else list(parameters), timeout)
        cursor._load_result(result)
        return cursor

    def close(self) -> None:
        if not self._closed:
            self.connection._ensure_open()
            self.connection._unwrap(self.connection._wire.request("close", {"statement_id": self.statement_id}))
            self._closed = True


class _PooledLease:
    def __init__(self, pool: "ConnectionPool", connection: Connection):
        self.pool = pool
        self.connection = connection

    def __enter__(self) -> Connection:
        return self.connection

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        try:
            if exc_type:
                self.connection.rollback()
            else:
                self.connection.commit()
        finally:
            self.pool.release(self.connection)


class ConnectionPool:
    """A bounded thread-safe pool of DB-API connections."""

    def __init__(self, url: Optional[str] = None, min_size: int = 1, max_size: int = 5, **options: Any):
        if max_size < 1 or min_size < 0 or min_size > max_size:
            raise InterfaceError("pool sizes must satisfy 0 <= min_size <= max_size")
        self.config = _parse_url(url, options) if url else dict(options)
        self.max_size = int(max_size)
        self._available: "queue.Queue[Connection]" = queue.Queue(maxsize=self.max_size)
        self._created = 0
        self._lock = threading.Condition()
        for _ in range(int(min_size)):
            self._available.put(self._new_connection())

    def _new_connection(self) -> Connection:
        with self._lock:
            self._created += 1
        try:
            return Connection(dict(self.config))
        except Exception:
            with self._lock:
                self._created -= 1
            raise

    @contextmanager
    def acquire(self, timeout: Optional[float] = None):
        start = time.monotonic()
        connection: Optional[Connection] = None
        try:
            while connection is None:
                try:
                    connection = self._available.get_nowait()
                except queue.Empty:
                    with self._lock:
                        if self._created < self.max_size:
                            connection = self._new_connection()
                            break
                    remaining = None if timeout is None else max(float(timeout) - (time.monotonic() - start), 0)
                    if remaining == 0:
                        raise OperationalError("timed out waiting for a RubyDB connection")
                    try:
                        connection = self._available.get(timeout=remaining)
                    except queue.Empty as exc:
                        raise OperationalError("timed out waiting for a RubyDB connection") from exc
            yield connection
        finally:
            if connection is not None:
                self.release(connection)

    def connection(self, timeout: Optional[float] = None) -> _PooledLease:
        start = time.monotonic()
        try:
            connection = self._available.get_nowait()
        except queue.Empty:
            with self._lock:
                if self._created < self.max_size:
                    connection = self._new_connection()
                else:
                    remaining = None if timeout is None else max(float(timeout) - (time.monotonic() - start), 0)
                    try:
                        connection = self._available.get(timeout=remaining)
                    except queue.Empty as exc:
                        raise OperationalError("timed out waiting for a RubyDB connection") from exc
        return _PooledLease(self, connection)

    def release(self, connection: Connection) -> None:
        if connection.closed:
            with self._lock:
                self._created -= 1
                self._lock.notify_all()
            return
        self._available.put(connection)

    def close(self) -> None:
        while True:
            try:
                connection = self._available.get_nowait()
            except queue.Empty:
                return
            connection.close()
            with self._lock:
                self._created -= 1


def connect(url: Optional[str] = None, **options: Any) -> Connection:
    """Open a RubyDB server connection.

    Example: ``connect(os.environ["RUBYDB_URL"])``.
    """
    if url is not None:
        config = _parse_url(url, options)
    else:
        config = dict(options)
        config.setdefault("host", "localhost")
        config.setdefault("port", 7432)
        config.setdefault("username", "rubydb")
        config.setdefault("password", "")
        config.setdefault("database", "rubydb")
        config.setdefault("ssl", False)
    return Connection(config)
