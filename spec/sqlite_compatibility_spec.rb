# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQLite compatibility profile" do
  it "supports the common SQLite-style schema, CRUD, transaction, and query surface" do
    Dir.mktmpdir("rubydb-sqlite") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "sqlite.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect

      connection.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT NOT NULL UNIQUE,
          active BOOLEAN NOT NULL DEFAULT TRUE
        )
      SQL
      connection.execute("INSERT INTO users (email, active) VALUES ('ada@example.test', TRUE)")
      connection.execute("INSERT INTO users (email, active) VALUES ('grace@example.test', FALSE)")
      connection.execute("UPDATE users SET active = TRUE WHERE email = 'grace@example.test'")

      rows = connection.execute(<<~SQL).to_a
        SELECT LOWER(email) AS email, active
        FROM users
        WHERE active = TRUE
        ORDER BY id ASC
        LIMIT 10 OFFSET 0
      SQL

      expect(rows).to eq([
        { "email" => "ada@example.test", "active" => true },
        { "email" => "grace@example.test", "active" => true }
      ])

      connection.begin_db_transaction
      connection.execute("INSERT INTO users (email, active) VALUES ('rollback@example.test', TRUE)")
      connection.rollback_db_transaction
      expect(connection.execute("SELECT COUNT(*) AS count FROM users").to_a).to eq([{ "count" => 2 }])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "supports SQLite-style grouped joins and conflict handling" do
    Dir.mktmpdir("rubydb-sqlite-query") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "sqlite.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT UNIQUE)")
      connection.execute("CREATE TABLE members (id INTEGER PRIMARY KEY, team_id INTEGER, name TEXT)")
      connection.execute("INSERT INTO teams (id, name) VALUES (1, 'core')")
      connection.execute("INSERT INTO members (id, team_id, name) VALUES (1, 1, 'Ada')")
      connection.execute("INSERT INTO members (id, team_id, name) VALUES (2, 1, 'Grace')")
      connection.execute("INSERT INTO teams (id, name) VALUES (1, 'updated') ON CONFLICT (id) DO UPDATE SET name = excluded.name")

      result = connection.execute(<<~SQL).to_a
        SELECT teams.name, COUNT(members.id) AS member_count
        FROM teams INNER JOIN members ON teams.id = members.team_id
        GROUP BY teams.name HAVING member_count = 2
      SQL

      expect(result).to eq([{ "name" => "updated", "member_count" => 2 }])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
