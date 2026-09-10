<script lang="ts">
  import { onMount } from "svelte";

  type Note = { id: number | string | null; title: string };

  let notes: Note[] = [];
  let title = "";
  let status = "Loading RubyDB…";
  let saving = false;

  async function loadNotes() {
    const response = await fetch("/api/notes");
    if (!response.ok) throw new Error("RubyDB is unavailable");
    notes = (await response.json()).notes;
    status = "Connected to RubyDB";
  }

  async function addNote() {
    if (!title.trim() || saving) return;
    saving = true;
    try {
      const response = await fetch("/api/notes", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ title }),
      });
      if (!response.ok) throw new Error("Could not save note");
      title = "";
      await loadNotes();
    } catch (error) {
      status = error instanceof Error ? error.message : "Request failed";
    } finally {
      saving = false;
    }
  }

  onMount(() => {
    loadNotes().catch((error) => {
      status = error instanceof Error ? error.message : "RubyDB is unavailable";
    });
  });
</script>

<svelte:head>
  <title>SvelteKit + RubyDB</title>
  <meta name="description" content="A small SvelteKit app backed by RubyDB" />
</svelte:head>

<main>
  <p class="eyebrow">SvelteKit × RubyDB</p>
  <h1>Service notes</h1>
  <p class="status">{status}</p>

  <form onsubmit={(event) => { event.preventDefault(); addNote(); }}>
    <label for="title">New note</label>
    <div class="input-row">
      <input id="title" bind:value={title} placeholder="What should we remember?" maxlength="200" />
      <button disabled={saving || !title.trim()}>{saving ? "Saving…" : "Add note"}</button>
    </div>
  </form>

  {#if notes.length === 0}
    <p class="empty">No notes yet.</p>
  {:else}
    <ul>
      {#each notes as note}
        <li><span>#{note.id}</span>{note.title}</li>
      {/each}
    </ul>
  {/if}
</main>

<style>
  :global(body) { margin: 0; background: #10131a; color: #f4f7fb; font-family: system-ui, sans-serif; }
  main { max-width: 680px; margin: 12vh auto; padding: 2rem; }
  .eyebrow { color: #7dd3fc; letter-spacing: .08em; text-transform: uppercase; font-size: .8rem; }
  h1 { font-size: clamp(2.4rem, 8vw, 5rem); line-height: .95; margin: .5rem 0 1rem; }
  .status { color: #a7f3d0; }
  form { margin-top: 3rem; }
  label { display: block; margin-bottom: .5rem; color: #cbd5e1; }
  .input-row { display: flex; gap: .75rem; }
  input, button { border: 1px solid #334155; border-radius: .6rem; padding: .8rem 1rem; font: inherit; }
  input { background: #1e293b; color: #fff; flex: 1; }
  button { background: #38bdf8; color: #082f49; cursor: pointer; font-weight: 700; }
  button:disabled { cursor: wait; opacity: .55; }
  ul { list-style: none; padding: 0; margin-top: 2rem; display: grid; gap: .6rem; }
  li { background: #1e293b; border-radius: .6rem; padding: 1rem; }
  li span { color: #7dd3fc; margin-right: .75rem; }
  .empty { color: #94a3b8; margin-top: 2rem; }
</style>
