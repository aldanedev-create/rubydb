# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Incremental do
  it "captures WAL mutations after the base backup LSN" do
    Dir.mktmpdir do |dir|
      base_dir = File.join(dir, "backups", "backup_full_base")
      FileUtils.mkdir_p(base_dir)
      File.write(File.join(base_dir, "manifest.json"), JSON.generate(lsn: 0))
      wal = Object.new
      record = RubyDB::WAL::Record.new(:insert, { table_name: "users", values: { "id" => 1 } })
      record.instance_variable_set(:@lsn, RubyDB::WAL::LSN.new(0, 10))
      allow(wal).to receive(:read_all).and_return([record])
      engine = Struct.new(:wal).new(wal)

      incremental = described_class.new(engine,
        backup_dir: File.join(dir, "backups"),
        incremental_dir: File.join(dir, "incremental"))
      result = incremental.create_incremental("backup_full_base")

      expect(result[:success]).to be(true)
      expect(result[:metadata][:change_count]).to eq(1)
      expect(JSON.parse(File.read(File.join(result[:metadata] ? File.join(dir, "incremental", result[:incremental_name]) : "", "changes.json")))["changes"].size).to eq(1)
    end
  end

  it "rejects a tampered incremental on load" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "incremental", "inc_1")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "changes.json"), "{}")
      File.write(File.join(path, "metadata.json"), JSON.generate(name: "inc_1", checksum: "wrong", base_backup: "base", created_at: Time.now.iso8601))

      expect {
        described_class.new(Struct.new(:wal).new(nil), incremental_dir: File.join(dir, "incremental"))
      }.to raise_error(/checksum mismatch/)
    end
  end
end
