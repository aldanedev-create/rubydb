# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RubyDB::Accelerator do
  let(:binary) do
    pattern = File.expand_path("../accelerator/bin/rubydb-accelerator-*", __dir__)
    Dir[pattern].find { |path| File.extname(path) == ".exe" } || Dir[pattern].first
  end

  def client
    described_class::Client.new(mode: "required", binary: binary, timeout: 10, min_rows: 0)
  end

  it "verifies the Go protocol and safe utility operations" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    accelerator = client
    expect(accelerator.ping.fetch("protocol_version")).to eq(1)
    expect(accelerator.worker_metrics).to be_a(Hash)
    expect(accelerator.sha256("abc")).to eq("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    source = "rubydb-accelerator" * 100
    compressed = accelerator.gzip(source)
    expect(accelerator.gunzip(compressed)).to eq(source)
  ensure
    accelerator&.close
  end

  it "starts a bundled worker from an executable path containing spaces" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir("rubydb accelerator path ") do |dir|
      copied = File.join(dir, File.basename(binary))
      FileUtils.cp(binary, copied)
      accelerator = described_class::Client.new(mode: "required", binary: copied, timeout: 10, min_rows: 0)
      expect(accelerator.ping.fetch("protocol_version")).to eq(1)
    ensure
      accelerator&.close
    end
  end

  it "keeps the worker alive across requests and restarts it cleanly" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    accelerator = client
    expect(accelerator.ping.fetch("protocol_version")).to eq(1)
    first = accelerator.rows_pipeline([{"id" => 1}], projection: ["id"])
    expect(first[:rows]).to eq([{"id" => 1}])
    first_pid = accelerator.stats[:worker_pid]

    accelerator.restart
    expect(accelerator.ping.fetch("protocol_version")).to eq(1)
    second = accelerator.rows_pipeline([{"id" => 2}], projection: ["id"])
    expect(second[:rows]).to eq([{"id" => 2}])
    stats = accelerator.stats

    expect(stats[:worker_starts]).to be >= 2
    expect(stats[:worker_restarts]).to be >= 1
    expect(stats[:worker_pid]).not_to eq(first_pid) if first_pid
  ensure
    accelerator&.close
  end

  it "keeps filtering, ordering, and NULL behavior equivalent to Ruby" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    rows = [
      {"id" => 3, "name" => "Ruby", "deleted_at" => nil},
      {"id" => 1, "name" => "Rails", "deleted_at" => "2026-01-01"},
      {"id" => 2, "name" => "RubyDB", "deleted_at" => nil}
    ]
    accelerator = client
    result = accelerator.rows_pipeline(
      rows,
      filters: [{column: "deleted_at", operator: "is_null"}],
      order_by: [{column: "id", direction: "desc"}]
    )

    expect(result[:rows].map { |row| row["id"] }).to eq([3, 2])
  ensure
    accelerator&.close
  end

  it "executes projection, DISTINCT, windows, merge joins, and WAL preparation" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    accelerator = client
    result = accelerator.rows_pipeline(
      [{"id" => 2, "group" => "a"}, {"id" => 1, "group" => "a"}, {"id" => 1, "group" => "a"}],
      projection: ["group", "id"], distinct: true,
      windows: [{function: "row_number", alias: "position", partition_by: ["group"], order_by: [{column: "id", direction: "asc"}]}]
    )
    expect(result[:rows].map { |row| row["position"] }).to contain_exactly(1, 2)

    streamed = accelerator.rows_pipeline_stream((0...25).map { |id| {"id" => id} }, projection: ["id"], batch_size: 7)
    expect(streamed[:row_count]).to eq(25)
    expect(streamed[:rows].map { |row| row["id"] }).to eq((0...25).to_a)

    joined = accelerator.merge_join([{"id" => 1}], [{"id" => 1, "value" => "ok"}], left_key: "id", right_key: "id")
    expect(joined[:rows]).to eq([{"id" => 1, "value" => "ok"}])

    wal = accelerator.wal_batch([{kind: 1, lsn: 2, transaction: 3, payload: "approved"}], compress: true)
    expect(wal[:record_count]).to eq(1)
    expect(wal[:checksum]).to match(/\A[0-9a-f]{64}\z/)
    expect(wal[:compressed_base64]).to be_a(String)
  ensure
    accelerator&.close
  end

  it "multiplexes concurrent requests and cancels a timed-out pipeline" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    accelerator = described_class::Client.new(mode: "required", binary: binary, timeout: 5, min_rows: 0)
    threads = 8.times.map do |index|
      Thread.new { accelerator.rows_pipeline([{"id" => index}], projection: ["id"]) }
    end
    expect(threads.map(&:value).map { |result| result[:rows].first["id"] }).to contain_exactly(*(0...8))

    expect do
      accelerator.manager.request(
        "rows_pipeline",
        {rows: 100_000.times.map { |id| {"id" => id} }, filters: [{column: "id", operator: "gte", value: 0}]},
        timeout: 0.001
      )
    end.to raise_error(RubyDB::Accelerator::TimeoutError)
  ensure
    accelerator&.close
  end

  it "uses the accelerator for a large simple SELECT while preserving the Ruby result" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(
        File.join(dir, "accelerated.rdb"),
        auto_cleanup: false,
        auto_vacuum: false,
        accelerator: {mode: "required", binary: binary, timeout: 10, min_rows: 0}
      )
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:name, :text, null: false)
      ]
      engine.create_table(:users, columns)
      300.times { |id| engine.insert_row(:users, columns, [id, "user-#{id}"]) }
      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT id FROM users WHERE id >= 100 ORDER BY id DESC").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      executor = RubyDB::Execution::Executor.new(engine)
      result = executor.execute(plan)

      expect(result[:rows].map { |row| row["id"] }).to eq((100...300).to_a.reverse)
      expect(executor.stats[:accelerator_requests]).to be >= 1

      qualified_statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT users.id FROM users WHERE users.id >= 100 ORDER BY users.id DESC LIMIT 20").tokenize
      ).parse.first
      qualified_plan = RubyDB::Execution::Planner.new(engine).plan(qualified_statement)
      qualified_result = RubyDB::Execution::Executor.new(engine).execute(qualified_plan)
      expect(qualified_result[:rows].map { |row| row["id"] }).to eq((280...300).to_a.reverse)
    ensure
      engine&.close
    end
  end

  it "reads a consistent B-tree index snapshot without materializing Ruby scan rows" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(
        File.join(dir, "indexed-snapshot.rdb"),
        auto_cleanup: false,
        auto_vacuum: false,
        accelerator: {mode: "required", binary: binary, timeout: 10, min_rows: 0}
      )
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:name, :text, null: false)
      ]
      engine.create_table(:users, columns)
      300.times { |id| engine.insert_row(:users, columns, [id, "user-#{id}"]) }
      engine.index_manager.create_index("users_id_idx", "users", ["id"], type: :btree)

      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT id, name FROM users WHERE id >= 290 ORDER BY id").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      expect(plan.scan_type).to eq(:index)
      expect(plan.index.name.to_s).to eq("users_id_idx")

      result = RubyDB::Execution::Executor.new(engine).execute(plan)
      expect(result[:rows]).to eq((290...300).map { |id| {"id" => id, "name" => "user-#{id}"} })
    ensure
      engine&.close
    end
  end

  it "can execute a conservative grouped aggregate through the Go pipeline" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(
        File.join(dir, "aggregate.rdb"),
        auto_cleanup: false,
        auto_vacuum: false,
        accelerator: {mode: "required", binary: binary, timeout: 10, min_rows: 0}
      )
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, amount INTEGER)")
      300.times do |id|
        connection.execute("INSERT INTO sales (id, region, amount) VALUES (?, ?, ?)", [id, id.even? ? "east" : "west", id])
      end

      result = connection.execute(
        "SELECT region, COUNT(*) AS orders, SUM(amount) AS total FROM sales GROUP BY region"
      ).to_a

      expect(result).to contain_exactly(
        {"region" => "east", "orders" => 150, "total" => 22_350.0},
        {"region" => "west", "orders" => 150, "total" => 22_500.0}
      )
    ensure
      connection&.disconnect
      engine&.close
    end
  end

  it "can execute a validated inner hash join through the Go pipeline" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(
        File.join(dir, "join.rdb"),
        auto_cleanup: false,
        auto_vacuum: false,
        accelerator: {mode: "required", binary: binary, timeout: 10, min_rows: 0}
      )
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
      connection.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, total INTEGER)")
      connection.execute("INSERT INTO users (id, name) VALUES (1, 'A'), (2, 'B')")
      connection.execute("INSERT INTO orders (id, user_id, total) VALUES (10, 2, 9), (11, 1, 7)")

      result = connection.execute(
        "SELECT users.id, orders.total FROM users INNER JOIN orders ON users.id = orders.user_id ORDER BY users.id"
      ).to_a

      expect(result).to contain_exactly(
        {"id" => 1, "total" => 7},
        {"id" => 2, "total" => 9}
      )
    ensure
      connection&.disconnect
      engine&.close
    end
  end

  it "calibrates automatic scan selection without changing the result" do
    skip "build the accelerator first with ruby scripts/build_accelerator" unless binary && File.file?(binary)

    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(
        File.join(dir, "auto.rdb"),
        auto_cleanup: false,
        auto_vacuum: false,
        accelerator: {mode: "auto", binary: binary, timeout: 10, min_rows: 0}
      )
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:name, :text, null: false)
      ]
      engine.create_table(:users, columns)
      300.times { |id| engine.insert_row(:users, columns, [id, "user-#{id}"]) }
      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT id FROM users WHERE id >= 100 ORDER BY id DESC").tokenize
      ).parse.first
      plan = RubyDB::Execution::Planner.new(engine).plan(statement)
      result = RubyDB::Execution::Executor.new(engine).execute(plan)

      expect(result[:rows].map { |row| row["id"] }).to eq((100...300).to_a.reverse)
      expect(engine.accelerator.stats[:performance_decisions]).to have_key(:scan)
    ensure
      engine&.close
    end
  end
end
