# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "immutable table export" do
  def accelerator_tool
    pattern = File.expand_path("../accelerator/bin/rubydb-tools-*", __dir__)
    Dir[pattern].find { |path| File.extname(path) == ".exe" } || Dir[pattern].first
  end

  def output
    RubyDB::CLI::Output.new(no_color: true, quiet: true)
  end

  def columns
    [
      RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
      RubyDB::Catalog::Column.new(:name, :text),
      RubyDB::Catalog::Column.new(:active, :boolean),
      RubyDB::Catalog::Column.new(:ratio, :float),
      RubyDB::Catalog::Column.new(:created_at, :timestamp),
      RubyDB::Catalog::Column.new(:payload, :blob)
    ]
  end

  it "keeps the detached snapshot available while a writer proceeds" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "snapshot.rdb"), auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:items, columns)
      engine.insert_row(:items, columns, [1, "first", true, 1.0, Time.utc(2026, 1, 1), "a".b])

      snapshot_path = nil
      engine.with_export_snapshot do |snapshot|
        snapshot_path = snapshot.fetch(:snapshot_path)
        writer = Thread.new { engine.insert_row(:items, columns, [2, "second", false, 2.0, Time.utc(2026, 1, 2), "b".b]) }
        expect(writer.join(1)).to be_truthy
        expect(writer.value).to be_a(Integer)
        expect(File).to exist(snapshot_path)
      end
      expect(File).not_to exist(snapshot_path)
    ensure
      engine&.close
    end
  end

  it "rejects an export while an active transaction can change visibility" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "transaction.rdb"), auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:items, columns)
      engine.begin_transaction

      expect { engine.with_export_snapshot { |_| nil } }.to raise_error(RubyDB::StorageError, /no active transaction/)
    ensure
      engine&.rollback_transaction if engine&.in_transaction?
      engine&.close
    end
  end

  it "produces byte-identical Ruby and Go JSONL for a filtered projection" do
    skip "build rubydb-tools first with ruby scripts/build_accelerator" unless accelerator_tool && File.file?(accelerator_tool)

    Dir.mktmpdir do |dir|
      database = File.join(dir, "export.rdb")
      engine = RubyDB::Storage::Engine.new(database, auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:items, columns)
      engine.insert_row(:items, columns, [1, "include", true, 3.25, Time.utc(2026, 4, 5, 6, 7, 8), "\x00bin".b])
      engine.insert_row(:items, columns, [2, "exclude", false, 4.5, Time.utc(2026, 4, 5, 6, 7, 9), "ignore".b])
      engine.close

      ruby_out = File.join(dir, "ruby.jsonl")
      go_out = File.join(dir, "go.jsonl")
      args = ["--database", database, "--table", "items", "--columns", "name,ratio,created_at,payload",
        "--where", "active eq true", "--where", "created_at gte \"2026-04-05T06:07:08Z\""]
      command = RubyDB::CLI::Commands::Export.new(output, nil)
      expect(command.execute(args + ["--engine", "ruby", "--out", ruby_out], {})).to eq(0)
      expect(command.execute(args + ["--engine", "go", "--out", go_out], {})).to eq(0)

      expect(File.binread(go_out)).to eq(File.binread(ruby_out))
      expect(File).not_to exist("#{go_out}.partial")
      expect do
        command.execute(args + ["--engine", "go", "--out", go_out], {})
      end.to raise_error(RubyDB::StorageError, /already exists/)

      limited_out = File.join(dir, "limited.jsonl")
      expect do
        command.execute(["--database", database, "--table", "items", "--engine", "ruby", "--max-rows", "1", "--out", limited_out], {})
      end.to raise_error(RubyDB::StorageError, /row limit/)
      expect(File).not_to exist(limited_out)
      expect(File).not_to exist("#{limited_out}.partial")
    ensure
      engine&.close if engine&.open?
    end
  end
end
