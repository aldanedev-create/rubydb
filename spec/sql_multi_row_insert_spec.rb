# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL multi-row INSERT" do
  it "inserts every VALUES tuple and preserves expression evaluation" do
    Dir.mktmpdir("rubydb-multi-row-insert") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "rows.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name VARCHAR(64), active BOOLEAN)")

      result = connection.execute(<<~SQL)
        INSERT INTO users (id, name, active)
        VALUES (1, 'Ada', TRUE), (2, 'Grace', FALSE), (3, 'Linus', TRUE)
      SQL

      expect(result.row_count).to eq(3)
      expect(result.affected_rows).to eq(3)
      expect(connection.execute("SELECT id, name, active FROM users ORDER BY id").to_a).to eq([
        {"id" => 1, "name" => "Ada", "active" => true},
        {"id" => 2, "name" => "Grace", "active" => false},
        {"id" => 3, "name" => "Linus", "active" => true}
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "applies ON CONFLICT independently to each tuple" do
    Dir.mktmpdir("rubydb-multi-row-upsert") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "upsert.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE counters (id INTEGER PRIMARY KEY, value INTEGER)")
      connection.execute("INSERT INTO counters (id, value) VALUES (1, 10)")

      result = connection.execute(<<~SQL)
        INSERT INTO counters (id, value)
        VALUES (1, 20), (2, 30)
        ON CONFLICT (id) DO UPDATE SET value = excluded.value
      SQL

      expect(result.row_count).to eq(2)
      expect(result.affected_rows).to eq(2)
      expect(connection.execute("SELECT id, value FROM counters ORDER BY id").to_a).to eq([
        {"id" => 1, "value" => 20},
        {"id" => 2, "value" => 30}
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "rolls back the whole implicit statement when one tuple violates a constraint" do
    Dir.mktmpdir("rubydb-multi-row-atomicity") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "atomic.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name VARCHAR(64))")
      connection.execute("INSERT INTO users (id, name) VALUES (1, 'existing')")

      expect do
        connection.execute("INSERT INTO users (id, name) VALUES (2, 'rolled back'), (1, 'duplicate')")
      end.to raise_error(RubyDB::DatabaseError)

      expect(connection.execute("SELECT id, name FROM users ORDER BY id").to_a).to eq([
        {"id" => 1, "name" => "existing"}
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
