import { connect } from "rubydb-node";

const url = process.env.RUBYDB_URL ?? "rubydb://rubydb@127.0.0.1:7432/rubydb";
const database = await connect(url);
database.isAutocommit = true;
try {
  await database.query(
    "CREATE TABLE IF NOT EXISTS sveltekit_notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
  );
} finally {
  await database.close();
}
console.log("RubyDB schema ready");
