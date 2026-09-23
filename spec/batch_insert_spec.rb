# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "batched embedded inserts" do
  def columns
    [
      RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
      RubyDB::Catalog::Column.new(:name, :text, null: false)
    ]
  end

  it "publishes metadata once while preserving every inserted row after reopen" do
    Dir.mktmpdir("rubydb-batch-insert") do |directory|
      path = File.join(directory, "events.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:events, columns)

      metadata_writes = 0
      allow(engine).to receive(:save_table_metadata).and_wrap_original do |original, *arguments|
        metadata_writes += 1
        original.call(*arguments)
      end
      ids = engine.insert_rows(:events, columns, [
        {id: 1, name: "created"},
        {id: 2, name: "paid"},
        {id: 3, name: "shipped"}
      ])

      expect(ids).to eq([1, 2, 3])
      expect(metadata_writes).to eq(1)
      engine.close
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      expect(engine.select_rows(:events, columns).map { |row| row[:name] }).to eq(%w[created paid shipped])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "uses the engine batch path for a simple multi-row SQL INSERT" do
    Dir.mktmpdir("rubydb-sql-batch-insert") do |directory|
      engine = RubyDB::Storage::Engine.new(File.join(directory, "events.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT)")

      expect(engine).to receive(:insert_rows).once.and_call_original
      result = connection.execute("INSERT INTO events (id, name) VALUES (1, 'created'), (2, 'paid')")

      expect(result.affected_rows).to eq(2)
      expect(connection.execute("SELECT id FROM events ORDER BY id").to_a).to eq([{"id" => 1}, {"id" => 2}])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "defers batch metadata publication to the durable transaction commit" do
    Dir.mktmpdir("rubydb-transaction-batch-insert") do |directory|
      engine = RubyDB::Storage::Engine.new(File.join(directory, "events.rdb"), auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:events, columns)
      metadata_writes = 0
      allow(engine).to receive(:save_table_metadata).and_wrap_original do |original, *arguments|
        metadata_writes += 1
        original.call(*arguments)
      end

      transaction_id = engine.begin_transaction
      engine.insert_rows(:events, columns, [{id: 1, name: "created"}, {id: 2, name: "paid"}])
      expect(metadata_writes).to eq(0)

      expect(engine.commit_transaction(transaction_id)).to be(true)
      expect(metadata_writes).to eq(1)
    ensure
      engine&.close if engine&.open?
    end
  end

  it "provides an embedded insert_many convenience API" do
    Dir.mktmpdir("rubydb-insert-many") do |directory|
      database = RubyDB.open(File.join(directory, "app.rdb"), auto_cleanup: false, auto_vacuum: false)
      database.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")

      ids = database.transaction do
        database.insert_many(:users, [{id: 1, name: "Ada"}, {id: 2, name: "Grace"}])
      end
      expect(ids).to eq([1, 2])
      expect(database.query("SELECT name FROM users ORDER BY id")).to eq([{"name" => "Ada"}, {"name" => "Grace"}])
    ensure
      database&.close
    end
  end
end
