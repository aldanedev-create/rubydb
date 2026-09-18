import assert from "node:assert/strict";
import { createServer, type Server } from "node:net";
import test from "node:test";

import { connect, ConnectionPool, TimeoutError } from "../src/index.js";

function envelope(type: string, payload: Record<string, any>, id = "server-message") {
  return {
    type,
    id,
    created_at: new Date().toISOString(),
    payload,
    compressed: false,
    encrypted: false,
    checksum: null,
  };
}

async function fakeRubyDB(): Promise<{ server: Server; port: number; requests: any[] }> {
  const requests: any[] = [];
  const server = createServer((socket) => {
    let buffer = "";
    const send = (type: string, payload: Record<string, any>) => socket.write(`${JSON.stringify(envelope(type, payload))}\n`);
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
        if (!line.trim()) continue;
        const request = JSON.parse(line);
        requests.push(request);
        switch (request.type) {
          case "handshake":
            send("handshake_response", { success: true });
            break;
          case "authentication_response":
            send("authentication", { success: true });
            break;
          case "synchronize":
            send("ready_for_query", { success: true });
            break;
          case "begin":
            send("begin_response", { success: true });
            break;
          case "commit":
            send("commit_response", { success: true });
            break;
          case "rollback":
            send("rollback_response", { success: true });
            break;
          case "query":
            send("query_response", {
              success: true,
              result: { columns: [{ name: "id" }], rows: [{ id: 1 }], row_count: 1, affected_rows: 0 },
            });
            break;
          case "prepare":
            send("prepare_response", { success: true, statement_id: "stmt-1" });
            break;
          case "execute":
            send("execute_response", {
              success: true,
              result: { columns: [{ name: "id" }], rows: [{ id: 1 }], row_count: 1, affected_rows: 0 },
            });
            break;
          case "close":
            send("close_response", { success: true });
            break;
          case "terminate":
            socket.end();
            break;
          default:
            send(`${request.type}_response`, { success: true });
        }
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  server.unref();
  return { server, port: (server.address() as import("node:net").AddressInfo).port, requests };
}

async function stopFixture(server: Server): Promise<void> {
  (server as Server & { closeAllConnections?: () => void }).closeAllConnections?.();
  await new Promise<void>((resolve) => server.close(() => resolve()));
}

test("connects, binds parameters, commits, and executes prepared statements", async () => {
  const fixture = await fakeRubyDB();
  const db = await connect(`rubydb://rubydb@127.0.0.1:${fixture.port}/test`);
  try {
    const result = await db.query("SELECT id FROM users WHERE active = ?", [true]);
    assert.deepEqual(result.rows, [{ id: 1 }]);
    const query = fixture.requests.find((request) => request.type === "query");
    assert.deepEqual(query.payload.params, [true]);
    await db.commit();

    const statement = await db.prepare("SELECT id FROM users WHERE id = ?");
    const prepared = await statement.execute([1]);
    assert.equal(prepared.rows[0]?.id, 1);
    await statement.close();
  } finally {
    await db.close();
    await stopFixture(fixture.server);
  }
});

test("creates and closes a bounded pool", async () => {
  const fixture = await fakeRubyDB();
  const pool = await ConnectionPool.create(`rubydb://rubydb@127.0.0.1:${fixture.port}/test`, { maxSize: 2 });
  try {
    const result = await pool.use((db) => db.query("SELECT 1"));
    assert.equal(result.rowCount, 1);
    assert.equal(pool.size, 1);
  } finally {
    await pool.close();
    await stopFixture(fixture.server);
  }
});

test("runs the live adapter test when RUBYDB_URL is configured", { skip: !process.env.RUBYDB_URL }, async () => {
  const db = await connect(process.env.RUBYDB_URL!);
  try {
    db.isAutocommit = true;
    await db.query("CREATE TABLE IF NOT EXISTS node_adapter_smoke (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    await db.query("DELETE FROM node_adapter_smoke");
    await db.query("INSERT INTO node_adapter_smoke (name) VALUES (?)", ["node"]);
    const result = await db.query("SELECT name FROM node_adapter_smoke WHERE name = ?", ["node"]);
    assert.equal(result.rows[0]?.name, "node");
  } finally {
    await db.close();
  }
});

test("exports a timeout error type", () => {
  assert.equal(new TimeoutError("timeout").name, "TimeoutError");
});
