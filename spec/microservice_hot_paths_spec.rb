# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "embedded microservice hot paths" do
  def open_database(path)
    RubyDB.open(path, accelerator: {mode: :off}, auto_cleanup: false)
  end

  it "bounds deserialization for indexed points, LIMIT, and COUNT" do
    Dir.mktmpdir("rubydb-hot-paths") do |dir|
      db = open_database(File.join(dir, "ops.rdb"))
      db.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")
      150.times { |n| db.execute("INSERT INTO items (id, name) VALUES (#{n + 1}, 'item')") }

      deserializations = 0
      allow(RubyDB::Storage::Deserializer).to receive(:deserialize_row).and_wrap_original do |original, *args|
        deserializations += 1
        original.call(*args)
      end

      expect(db.query("SELECT name FROM items WHERE id = 149")).to eq([{"name" => "item"}])
      expect(deserializations).to be <= 2
      deserializations = 0
      expect(db.query("SELECT name FROM items LIMIT 10").size).to eq(10)
      expect(deserializations).to be <= 10
      deserializations = 0
      expect(db.query("SELECT COUNT(*) AS total FROM items")).to eq([{"total" => 150}])
      expect(deserializations).to eq(0)

      db.execute("DELETE FROM items WHERE id = 149")
      expect(db.query("SELECT COUNT(*) AS total FROM items")).to eq([{"total" => 149}])
      db.close
    ensure
      db&.close
    end
  end

  it "preserves unique, composite, NULL, update, delete, rollback, and reopen semantics" do
    Dir.mktmpdir("rubydb-index-semantics") do |dir|
      path = File.join(dir, "constraints.rdb")
      db = open_database(path)
      db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE, tenant INTEGER, handle TEXT, UNIQUE(tenant, handle))")
      db.execute("INSERT INTO users (id, email, tenant, handle) VALUES (1, 'one', 7, 'a')")
      expect { db.execute("INSERT INTO users (id, email, tenant, handle) VALUES (1, 'two', 7, 'b')") }.to raise_error(RubyDB::ExecutionError, /duplicate/i)
      expect { db.execute("INSERT INTO users (id, email, tenant, handle) VALUES (2, 'one', 7, 'b')") }.to raise_error(RubyDB::ExecutionError, /duplicate/i)
      expect { db.execute("INSERT INTO users (id, email, tenant, handle) VALUES (2, 'two', 7, 'a')") }.to raise_error(RubyDB::ExecutionError, /duplicate/i)
      db.execute("INSERT INTO users (id, tenant, handle) VALUES (2, 7, 'b')")
      db.execute("INSERT INTO users (id, tenant, handle) VALUES (3, 8, 'b')")
      expect { db.execute("UPDATE users SET email = 'one' WHERE id = 2") }.to raise_error(RubyDB::ExecutionError, /duplicate/i)
      expect(db.execute("UPDATE users SET email = 'one' WHERE id = 1")[:affected_rows]).to eq(1)
      db.execute("DELETE FROM users WHERE id = 1")
      db.execute("INSERT INTO users (id, email, tenant, handle) VALUES (4, 'one', 7, 'a')")
      db.close

      reopened = open_database(path)
      expect { reopened.execute("INSERT INTO users (id, email, tenant, handle) VALUES (5, 'one', 7, 'c')") }.to raise_error(RubyDB::ExecutionError, /duplicate/i)
      # The first post-reopen insert creates a partial in-memory locator map.
      # A lookup of an older row must rebuild it instead of treating that map
      # as complete and returning a false miss.
      reopened.execute("INSERT INTO users (id, tenant, handle) VALUES (6, 9, 'z')")
      expect(reopened.query("SELECT id FROM users WHERE email = 'one'")).to eq([{"id" => 4}])
      reopened.close
    ensure
      db&.close
      reopened&.close
    end
  end

  it "rejects another thread's uncommitted duplicate and releases keys on rollback" do
    Dir.mktmpdir("rubydb-tx-index") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "tx.rdb"), auto_cleanup: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      engine.create_table(:items, columns)
      ready = Queue.new
      release = Queue.new
      writer = Thread.new do
        engine.begin_transaction
        engine.insert_row(:items, columns, {id: 17})
        ready << true
        release.pop
        engine.rollback_transaction
      end
      ready.pop
      expect { engine.insert_row(:items, columns, {id: 17}) }.to raise_error(RubyDB::DatabaseError, /duplicate/i)
      release << true
      writer.join
      expect { engine.insert_row(:items, columns, {id: 17}) }.not_to raise_error
      engine.close
    ensure
      release << true if writer&.alive?
      writer&.join
      engine&.close
    end
  end
end
