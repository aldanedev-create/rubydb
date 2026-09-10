# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
RSpec.describe "SQL conflict handling" do
  it "ignores only duplicate-key inserts with ON CONFLICT DO NOTHING" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "upsert.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(64) UNIQUE)")
      connection.execute("INSERT INTO users (id, email) VALUES (1, 'a@example.test')")
      result = connection.execute("INSERT INTO users (id, email) VALUES (1, 'b@example.test') ON CONFLICT DO NOTHING")
      expect(result.affected_rows).to eq(0)
      expect(connection.execute("SELECT email FROM users").to_a).to eq([{"email" => "a@example.test"}])
      expect { connection.execute("INSERT INTO missing (id) VALUES (1) ON CONFLICT DO NOTHING") }.to raise_error(RubyDB::DatabaseError)
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "updates the conflicting row with an explicit target and EXCLUDED values" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "upsert-update.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(64) UNIQUE)")
      connection.execute("INSERT INTO users (id, email) VALUES (1, 'old@example.test')")

      result = connection.execute("INSERT INTO users (id, email) VALUES (1, 'new@example.test') ON CONFLICT (id) DO UPDATE SET email = excluded.email")
      expect(result.affected_rows).to eq(1)
      expect(connection.execute("SELECT id, email FROM users").to_a).to eq([{"id" => 1, "email" => "new@example.test"}])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "infers a unique constraint for targetless DO UPDATE" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "upsert-unique.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (email VARCHAR(64) UNIQUE, active BOOLEAN)")
      connection.execute("INSERT INTO users (email, active) VALUES ('a@example.test', FALSE)")

      result = connection.execute(<<~SQL)
        INSERT INTO users (email, active) VALUES ('a@example.test', TRUE)
        ON CONFLICT DO UPDATE SET active = excluded.active
      SQL
      expect(result.affected_rows).to eq(1)
      expect(connection.execute("SELECT active FROM users").to_a).to eq([{"active" => true}])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
