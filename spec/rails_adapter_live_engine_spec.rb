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
      expect(adapter.dump_schema).to include('t.boolean "active", default: FALSE, null: false')
    ensure
      adapter&.close
      engine&.close if engine&.open?
    end
  end
end
