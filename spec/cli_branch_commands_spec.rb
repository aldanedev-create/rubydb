# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "CLI branch commands" do
  def output_spy
    messages = []
    output = Object.new
    output.define_singleton_method(:puts) { |message = nil, *_styles| messages << message.to_s }
    output.define_singleton_method(:heading) { |message, *_styles| messages << message.to_s }
    output.define_singleton_method(:success) { |message| messages << "SUCCESS: #{message}" }
    output.define_singleton_method(:error) { |message| messages << "ERROR: #{message}" }
    output.define_singleton_method(:info) { |message| messages << "INFO: #{message}" }
    output.define_singleton_method(:spinner) { |_message, &block| block.call }
    [output, messages]
  end

  it "reads diff results from the persisted branch catalog" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "cli.rdb")
      branch_dir = File.join(dir, "branches")
      engine = RubyDB::Storage::Engine.new(database_path, auto_vacuum: false)
      engine.close
      output, messages = output_spy

      result = RubyDB::CLI::Commands::Diff.new(output, nil).execute(
        ["main", "main", "--summary", "--database", database_path, "--branch-dir", branch_dir], {}
      )

      expect(result).to eq(0), messages.inspect
      expect(messages.join("\n")).to include("Added changes: 0").or include("Added tables: 0")
      expect(messages.join("\n")).not_to include("posts")
    end
  end

  it "rejects missing merge and checkout targets without claiming success" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "cli.rdb")
      branch_dir = File.join(dir, "branches")
      engine = RubyDB::Storage::Engine.new(database_path, auto_vacuum: false)
      engine.close

      output, messages = output_spy
      expect {
        RubyDB::CLI::Commands::Merge.new(output, nil).execute(
          ["missing", "--database", database_path, "--branch-dir", branch_dir], {}
        )
      }.to raise_error(/not found/)
      expect(messages.grep(/SUCCESS/)).to be_empty

      expect {
        RubyDB::CLI::Commands::Checkout.new(output, nil).execute(
          ["missing", "--database", database_path, "--branch-dir", branch_dir], {}
        )
      }.to raise_error(/not found/)
      expect(messages.grep(/SUCCESS/)).to be_empty
    end
  end

  it "reports live inspection values" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "cli.rdb")
      engine = RubyDB::Storage::Engine.new(database_path, auto_vacuum: false)
      engine.create_table("events", [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)])
      engine.close
      output, messages = output_spy

      result = RubyDB::CLI::Commands::Inspect.new(output, nil).execute(
        ["--stats", "--database", database_path], {}
      )

      expect(result).to eq(0), messages.inspect
      expect(messages.join("\n")).to include("table_count: 1")
      expect(messages.join("\n")).not_to include("Total tables: 12")
    end
  end

  it "creates and lists real snapshots and runs live vacuum" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "cli.rdb")
      snapshot_dir = File.join(dir, "snapshots")
      engine = RubyDB::Storage::Engine.new(database_path, auto_vacuum: false)
      engine.close
      output, messages = output_spy
      formatter = Object.new
      listed = nil
      formatter.define_singleton_method(:format_snapshots) { |snapshots| listed = snapshots }

      expect(RubyDB::CLI::Commands::Snapshot.new(output, formatter).execute(
        ["--name", "snap_1", "--database", database_path, "--dir", snapshot_dir], {}
      )).to eq(0)
      expect(File.directory?(File.join(snapshot_dir, "snap_1"))).to be(true)

      expect(RubyDB::CLI::Commands::Snapshot.new(output, formatter).execute(
        ["--list", "--database", database_path, "--dir", snapshot_dir], {}
      )).to eq(0)
      expect(listed.map { |snapshot| snapshot[:name] }).to include("snap_1")

      expect(RubyDB::CLI::Commands::Vacuum.new(output, formatter).execute(
        ["--database", database_path], {}
      )).to eq(0)
      expect(messages.join("\n")).to include("Vacuum completed")
    end
  end

  it "creates real backups, closes the engine, and validates restore dry-run" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "cli.rdb")
      backup_dir = File.join(dir, "backups")
      engine = RubyDB::Storage::Engine.new(database_path, auto_vacuum: false)
      engine.close
      output, messages = output_spy

      result = RubyDB::CLI::Commands::Backup.new(output, nil).execute(
        ["--database", database_path, "--dir", backup_dir, "--no-verify"], {}
      )
      expect(result).to eq(0), messages.inspect
      backup_path = Dir.glob(File.join(backup_dir, "backup_*"), File::FNM_DOTMATCH).find { |path| File.directory?(path) }
      expect(backup_path).not_to be_nil

      backup_name = File.basename(backup_path)
      expect(RubyDB::CLI::Commands::Restore.new(output, nil).execute(
        ["--backup", backup_name, "--dry-run", "--database", database_path, "--dir", backup_dir], {}
      )).to eq(0)
      expect(messages.join("\n")).to include("Would restore")
    end
  end

  it "creates and drops a real database file" do
    Dir.mktmpdir do |dir|
      database_path = File.join(dir, "created.rdb")
      output, messages = output_spy

      expect(RubyDB::CLI::Commands::Create.new(output, nil).execute(
        ["--database", database_path], {}
      )).to eq(0)
      expect(File.file?(database_path)).to be(true)
      expect(RubyDB::CLI::Commands::Create.new(output, nil).execute(
        ["--database", database_path], {}
      )).to eq(1)
      expect(RubyDB::CLI::Commands::Drop.new(output, nil).execute(
        ["--database", database_path, "--force"], {}
      )).to eq(0)
      expect(File.exist?(database_path)).to be(false)
      expect(messages.join("\n")).to include("Database rubydb dropped")
    end
  end
end
