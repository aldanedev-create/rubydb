"""Python client adapter for the RubyDB server."""

from .dbapi import (
    Connection,
    ConnectionPool,
    Cursor,
    DataError,
    DatabaseError,
    Error,
    IntegrityError,
    InterfaceError,
    InternalError,
    NotSupportedError,
    OperationalError,
    ProgrammingError,
    PreparedStatement,
    Warning,
    connect,
)

__version__ = "0.1.0"
apilevel = "2.0"
threadsafety = 2
paramstyle = "qmark"

__all__ = [
    "Connection",
    "ConnectionPool",
    "Cursor",
    "DataError",
    "DatabaseError",
    "Error",
    "IntegrityError",
    "InterfaceError",
    "InternalError",
    "NotSupportedError",
    "OperationalError",
    "ProgrammingError",
    "PreparedStatement",
    "Warning",
    "connect",
]
