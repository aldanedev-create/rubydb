import { json } from "@sveltejs/kit";
import type { RequestHandler } from "./$types";

import { withDatabase } from "$lib/server/database";

export const GET: RequestHandler = async () => {
  try {
    await withDatabase((database) => database.ping());
    return json({ ok: true, database: "ready" });
  } catch {
    return json({ ok: false, database: "unavailable" }, { status: 503 });
  }
};
