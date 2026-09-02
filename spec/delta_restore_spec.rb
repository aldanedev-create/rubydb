# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "backup delta formats" do
  it "creates a verified differential delta from a valid base" do
    Dir.mktmpdir do |dir|
      base = File.join(dir, "backups", "backup_full_base")
      FileUtils.mkdir_p(base)
      File.write(File.join(base, "manifest.json"), JSON.generate(lsn: 0, files: []))
      wal = Object.new
      allow(wal).to receive(:read_all).and_return([])
      engine = Struct.new(:wal).new(wal)
      backup = RubyDB::Backup::Backup.new(engine, backup_dir: File.join(dir, "backups"), include_wal: false)

      result = backup.create_backup(type: RubyDB::Backup::Backup::TYPE_DIFFERENTIAL,
                                    base_backup: "backup_full_base")

      expect(result[:success]).to be(true)
      expect(result[:metadata][:type].to_s).to eq("differential")
    end
  end
end
