import { connect, type Connection } from "@dbs/rubydb";

const DEFAULT_URL = "rubydb://rubydb@127.0.0.1:7432/rubydb";

export function databaseUrl(): string {
  return process.env.RUBYDB_URL ?? DEFAULT_URL;
}

export async function withDatabase<T>(operation: (database: Connection) => Promise<T>): Promise<T> {
  const database = await connect(databaseUrl());
  database.isAutocommit = true;
  try {
    return await operation(database);
  } finally {
    await database.close();
  }
}

export async function initializeSchema(): Promise<void> {
  await withDatabase(async (database) => {
    await database.query(
      "CREATE TABLE IF NOT EXISTS sveltekit_notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
    );
  });
}
