"""Database helpers for the Flask example."""

from __future__ import annotations

import os
from collections.abc import Callable
from typing import Any, TypeVar

from rubydb import Connection, connect


DEFAULT_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb"
T = TypeVar("T")


def database_url() -> str:
    return os.environ.get("RUBYDB_URL", DEFAULT_URL)


def with_connection(operation: Callable[[Connection], T]) -> T:
    with connect(database_url(), timeout=5) as connection:
        return operation(connection)


def list_notes() -> list[dict[str, Any]]:
    def query(connection: Connection) -> list[dict[str, Any]]:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id, title FROM flask_notes ORDER BY id")
            return cursor.fetchall()

    return with_connection(query)


def insert_note(title: str) -> dict[str, Any]:
    def insert(connection: Connection) -> dict[str, Any]:
        with connection.cursor() as cursor:
            cursor.execute("INSERT INTO flask_notes (title) VALUES (?)", [title])
            return {"id": cursor.lastrowid, "title": title}

    return with_connection(insert)


def initialize_schema() -> None:
    def create(connection: Connection) -> None:
        with connection.cursor() as cursor:
            cursor.execute(
                "CREATE TABLE IF NOT EXISTS flask_notes "
                "(id INTEGER PRIMARY KEY, title TEXT NOT NULL)"
            )

    with_connection(create)

