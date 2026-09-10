"""Small Flask API backed by RubyDB server mode."""

from __future__ import annotations

from flask import Flask, request
from rubydb import Error as RubyDBError

from db import database_url, list_notes, insert_note, with_connection


def create_app() -> Flask:
    app = Flask(__name__)

    @app.get("/health")
    def health():
        try:
            with_connection(lambda connection: connection.ping())
        except RubyDBError:
            return {"ok": False, "database": "unavailable"}, 503
        return {"ok": True, "database": "ready"}

    @app.get("/notes")
    def notes():
        try:
            return {"notes": list_notes()}
        except RubyDBError:
            return {"error": "database unavailable"}, 503

    @app.post("/notes")
    def create_note():
        payload = request.get_json(silent=True)
        title = payload.get("title") if isinstance(payload, dict) else None
        if not isinstance(title, str) or not title.strip():
            return {"error": "title must be a non-empty string"}, 400
        try:
            return {"note": insert_note(title.strip())}, 201
        except RubyDBError:
            return {"error": "database unavailable"}, 503

    @app.get("/config-check")
    def config_check():
        """Show safe connection metadata without exposing credentials."""
        return {"rubydb_url_configured": bool(database_url())}

    return app


app = create_app()

