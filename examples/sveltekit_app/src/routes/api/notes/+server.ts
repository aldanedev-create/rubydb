import { json } from "@sveltejs/kit";
import type { RequestHandler } from "./$types";

import { withDatabase } from "$lib/server/database";

export const GET: RequestHandler = async () => {
  try {
    const result = await withDatabase(async (database) =>
      database.query("SELECT id, title FROM sveltekit_notes ORDER BY id"),
    );
    return json({ notes: result.rows });
  } catch {
    return json({ error: "database unavailable" }, { status: 503 });
  }
};

export const POST: RequestHandler = async ({ request }) => {
  const payload = await request.json().catch(() => null);
  const title = payload && typeof payload === "object" ? (payload as { title?: unknown }).title : null;
  if (typeof title !== "string" || !title.trim()) {
    return json({ error: "title must be a non-empty string" }, { status: 400 });
  }

  try {
    const result = await withDatabase(async (database) =>
      database.query("INSERT INTO sveltekit_notes (title) VALUES (?)", [title.trim()]),
    );
    return json({ note: { id: result.insertId, title: title.trim() } }, { status: 201 });
  } catch {
    return json({ error: "database unavailable" }, { status: 503 });
  }
};
