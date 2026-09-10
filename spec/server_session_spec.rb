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
        authorization: {users: {"reader" => {permissions: [:read]}}}
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

  it "rejects an expired deadline before a statement can mutate the engine" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "deadline.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      engine.create_table("users", columns)
      session = RubyDB::Server::Session.new(nil, engine: engine)

      response = session.process(type: "query", sql: "INSERT INTO users (id) VALUES (1)", deadline_at: (Time.now - 1).iso8601)
      expect(response).to include(success: false, code: "deadline_exceeded")
      expect(engine.select_rows("users", columns)).to be_empty
    ensure
      engine&.close if engine&.open?
    end
  end

  it "accepts a future deadline and executes the request" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "deadline-future.rdb"), auto_vacuum: false)
      engine.create_table("users", [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)])
      session = RubyDB::Server::Session.new(nil, engine: engine)
      session.authenticate(username: "rubydb", database: "rubydb")

      response = session.process(
        type: "query",
        sql: "INSERT INTO users (id) VALUES (1)",
        deadline_at: (Time.now + 5).iso8601
      )

      expect(response[:success]).to be(true)
      expect(engine.table_row_count("users")).to eq(1)
    ensure
      engine&.close
    end
  end

  it "enforces an execution deadline inside the executor" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "executor-deadline.rdb"), auto_vacuum: false)
      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT 1").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)

      expect {
        RubyDB::Execution::Executor.new(engine, deadline_at: Time.now - 1).execute(plan)
      }.to raise_error(RubyDB::ExecutionError) { |error|
        expect(error.code).to eq("deadline_exceeded")
      }
    ensure
      engine&.close if engine&.open?
    end
  end

  it "reports a durable commit acknowledgement after the WAL boundary" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "commit-ack.rdb"), auto_vacuum: false)
      engine.create_table("users", [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)])
      session = RubyDB::Server::Session.new(nil, engine: engine)
      session.authenticate(username: "rubydb", database: "rubydb")
      expect(session.process(type: "begin")[:success]).to be(true)
      expect(session.process(type: "query", sql: "INSERT INTO users (id) VALUES (1)")[:success]).to be(true)

      response = session.process(type: "commit")

      expect(response).to include(success: true, committed: true, durable: true)
      expect(response[:commit_ack]).to include(status: :durable, recovery_required: false)
      expect(response[:commit_ack][:transaction_id]).to be_a(Integer)
    ensure
      engine&.close
    end
  end

  it "marks a post-WAL flush failure as durable but recovery-required" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "commit-flush-failure.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)]
      engine.create_table("users", columns)
      engine.begin_transaction
      engine.insert_row("users", columns, [1])
      original_flush = engine.method(:flush)
      engine.define_singleton_method(:flush) { raise RubyDB::StorageError, "simulated disk full" }

      expect(engine.commit_transaction).to be(true)
      expect(engine.last_commit_ack).to include(status: :durable, recovery_required: true)
      expect(engine.last_commit_ack[:flush_error]).to include("simulated disk full")
      engine.define_singleton_method(:flush, &original_flush)
    ensure
      engine&.close if engine&.open?
    end
  end
end
