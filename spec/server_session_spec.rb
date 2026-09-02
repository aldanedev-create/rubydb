# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "server session execution" do
  it "executes SQL through an engine-backed session and rolls back on close" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "server.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      engine.create_table("users", columns)
      session = RubyDB::Server::Session.new(nil, engine: engine)
      session.authenticate(username: "tester", database: "server")

      created = session.process(type: "query", sql: "INSERT INTO users (id) VALUES (1)")
      queried = session.process(type: "query", sql: "SELECT * FROM users WHERE id = 1")

      expect(created[:success]).to be(true)
      expect(queried[:result][:rows].map { |row| row["id"] || row[:id] }).to eq([1])

      session.process(type: "begin")
      session.process(type: "query", sql: "INSERT INTO users (id) VALUES (2)")
      session.close
      expect(engine.select_rows("users", columns).map { |row| row["id"] || row[:id] }).to eq([1])
      engine.close
    ensure
      engine&.close
    end
  end

  it "enforces configured read/write permissions at the session boundary" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "server.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      engine.create_table("users", columns)
      session = RubyDB::Server::Session.new(
        nil,
        engine: engine,
        authorization: { users: { "reader" => { permissions: [:read] } } }
      )
      session.authenticate(username: "reader", database: "server")

      expect(session.process(type: "query", sql: "SELECT * FROM users")[:success]).to be(true)
      denied = session.process(type: "query", sql: "INSERT INTO users (id) VALUES (1)")
      expect(denied[:success]).to be(false)
      expect(denied[:error]).to include("write access")
      engine.close
    ensure
      engine&.close
    end
  end
end
