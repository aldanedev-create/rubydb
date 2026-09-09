# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "Rails adapter with a live RubyDB engine" do
  it "executes DDL, introspects the real catalog, runs bound queries, and manages transactions" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "adapter.rdb"), auto_vacuum: false)
      adapter = RubyDB::Rails::Adapter.new(engine: engine)

      adapter.create_table("users") do |table|
        table.primary_key("id")
        table.string("name", null: false)
        table.boolean("active", default: false, null: false)
      end
      adapter.add_index("users", "name", unique: true)
      insert_result = adapter.exec_insert("INSERT INTO users (id, name, active) VALUES (?, ?, ?)", nil,
                                         [Struct.new(:value).new(1), Struct.new(:value).new("Ada"), Struct.new(:value).new(true)])

      expect(insert_result).to include(row_count: 1, last_insert_id: 1)

      expect(adapter.tables).to include("users")
      expect(adapter.primary_key("users")).to eq("id")
      expect(adapter.columns("users")).to include(hash_including(name: "active", default: false, null: false))
      expect(adapter.indexes("users")).to include(hash_including(name: "idx_users_name", columns: ["name"], unique: true))
      expect(adapter.select_value("SELECT name FROM users WHERE id = ?", nil,
                                  [Struct.new(:value).new(1)])).to eq("Ada")
      adapter.exec_insert("INSERT INTO users (id, name, active) VALUES (?, ?, ?)", nil,
                          [Struct.new(:value).new(3), Struct.new(:value).new("O'Connor ?"), Struct.new(:value).new(true)])
      expect(adapter.select_value("SELECT name FROM users WHERE name = ?", nil,
                                  [Struct.new(:value).new("O'Connor ?")])).to eq("O'Connor ?")

      adapter.begin_db_transaction
      adapter.exec_insert("INSERT INTO users (id, name, active) VALUES (2, 'Grace', TRUE)")
      adapter.rollback_db_transaction

      expect(adapter.select_values("SELECT name FROM users ORDER BY id")).to eq(["Ada", "O'Connor ?"])
      expect(adapter.dump_schema).to include('t.boolean "active", default: false, null: false')
      expect(adapter.dump_schema).to include('add_index "users", ["name"], unique: true')
    ensure
      adapter&.close
      engine&.close if engine&.open?
    end
  end

  it "round-trips schema dumps including automatic keys, defaults, and indexes" do
    Dir.mktmpdir do |dir|
      source_engine = RubyDB::Storage::Engine.new(File.join(dir, "source.rdb"), auto_vacuum: false)
      source = RubyDB::Rails::Adapter.new(engine: source_engine)
      source.create_table("accounts") do |table|
        table.string("email", null: false)
        table.boolean("active", default: false, null: false)
      end
      source.add_index("accounts", "email", unique: true)
      schema = source.dump_schema

      target_engine = RubyDB::Storage::Engine.new(File.join(dir, "target.rdb"), auto_vacuum: false)
      target = RubyDB::Rails::Adapter.new(engine: target_engine)
      target.instance_eval(schema)

      expect(target.columns("accounts").map { |column| column[:name] }).to include("id", "email", "active")
      expect(target.columns("accounts").find { |column| column[:name] == "active" }).to include(default: false, null: false)
      expect(target.indexes("accounts")).to include(hash_including(name: "idx_accounts_email", unique: true))
      expect(schema).not_to include('t.integer "id"')
    ensure
      source&.close
      target&.close
      source_engine&.close if source_engine&.open?
      target_engine&.close if target_engine&.open?
    end
  end
end
