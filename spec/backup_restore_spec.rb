# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "RubyDB backup and restore" do
  it "round-trips database pages and persisted metadata" do
    Dir.mktmpdir do |dir|
      source_dir = File.join(dir, "source")
      restored_dir = File.join(dir, "restored")
      backup_dir = File.join(dir, "backups")
      FileUtils.mkdir_p(source_dir)

      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      engine = RubyDB::Storage::Engine.new(File.join(source_dir, "rubydb.rdb"), auto_vacuum: false)
      engine.create_table("users", columns)
      engine.insert_row("users", columns, [7])
      engine.storage_manager.flush
      engine.close

      backup = RubyDB::Backup::Backup.new(
        engine,
        backup_dir: backup_dir,
        format: RubyDB::Backup::Backup::FORMAT_COMPRESSED,
        include_wal: false,
        include_schema: false
      )
      created = backup.create_backup
      expect(created[:success]).to be(true)
      expect(backup.verify_backup(created[:backup_path])[:success]).to be(true)
      verification = RubyDB::Backup::Verification.new(verification_dir: File.join(dir, "verification"))
      expect(verification.verify_backup(created[:backup_path])[:success]).to be(true)

      restored = RubyDB::Backup::Restore.new(nil, backup_dir: backup_dir)
      result = restored.restore(created[:backup_path], destination: restored_dir)
      expect(result[:success]).to be(true)

      reopened = RubyDB::Storage::Engine.new(File.join(restored_dir, "rubydb.rdb"), auto_vacuum: false)
      expect(reopened.list_tables.map(&:to_s)).to include("users")
      expect(reopened.select_rows(:users, columns).map { |row| row[:id] || row["id"] }).to eq([7])
      reopened.close
    ensure
      engine&.close
      reopened&.close
    end
  end

  it "detects tampering and refuses incremental backups from an invalid base" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "rubydb.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false)]
      engine.create_table("users", columns)
      engine.insert_row("users", columns, [1])
      engine.storage_manager.flush
      engine.close

      backup = RubyDB::Backup::Backup.new(engine, backup_dir: File.join(dir, "backups"), include_wal: false, include_schema: false)
      created = backup.create_backup
      data_file = File.join(created[:backup_path], created[:metadata][:files].first)
      File.open(data_file, "ab") { |file| file.write("tampered") }
      expect(backup.verify_backup(created[:backup_path])[:success]).to be(false)

      incremental = backup.create_backup(type: RubyDB::Backup::Backup::TYPE_INCREMENTAL)
      expect(incremental[:success]).to be(false)
      expect(incremental[:error]).to include("Base backup verification failed")
    ensure
      engine&.close
    end
  end
end
