const baseUrl = process.env.BASE_URL ?? "http://127.0.0.1:5173";

const health = await fetch(`${baseUrl}/api/health`);
if (!health.ok || !(await health.json()).ok) throw new Error("health check failed");

const created = await fetch(`${baseUrl}/api/notes`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ title: "SvelteKit + RubyDB" }),
});
if (created.status !== 201) throw new Error(`create failed with ${created.status}`);

const notes = await fetch(`${baseUrl}/api/notes`);
const payload = await notes.json();
if (!notes.ok || !payload.notes.some((note) => note.title === "SvelteKit + RubyDB")) {
  throw new Error("read-back verification failed");
}

console.log("SvelteKit smoke test passed against RubyDB");
