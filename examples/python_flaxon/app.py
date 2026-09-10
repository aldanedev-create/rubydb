"""Small async Flaxon API backed by RubyDB server mode."""

from __future__ import annotations

import asyncio

from flaxon import Flaxon
from flaxon.http.response import JSONResponse
from rubydb import Error as RubyDBError

from db import database_url, insert_note, list_notes, ping


app = Flaxon("rubydb-flaxon-example", debug=False)


@app.get("/rubydb-health")
async def health():
    try:
        await asyncio.to_thread(ping)
    except RubyDBError:
        return JSONResponse({"ok": False, "database": "unavailable"}, status_code=503)
    return {"ok": True, "database": "ready"}


@app.get("/notes")
async def notes():
    try:
        return {"notes": await asyncio.to_thread(list_notes)}
    except RubyDBError:
        return JSONResponse({"error": "database unavailable"}, status_code=503)


@app.post("/notes")
async def create_note(request):
    payload = await request.json()
    title = payload.get("title") if isinstance(payload, dict) else None
    if not isinstance(title, str) or not title.strip():
        return JSONResponse({"error": "title must be a non-empty string"}, status_code=400)
    try:
        note = await asyncio.to_thread(insert_note, title.strip())
    except RubyDBError:
        return JSONResponse({"error": "database unavailable"}, status_code=503)
    return JSONResponse({"note": note}, status_code=201)


@app.get("/config-check")
async def config_check():
    """Show safe connection metadata without exposing credentials."""
    return {"rubydb_url_configured": bool(database_url())}
