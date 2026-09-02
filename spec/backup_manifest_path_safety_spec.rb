# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "backup manifest path safety" do
  it "rejects manifest entries that escape a backup during verification and restore" do
    Dir.mktmpdir do |dir|
      backup_path = File.join(dir, "backup_full_test")
      destination = File.join(dir, "restore")
      FileUtils.mkdir_p(backup_path)
      File.write(File.join(dir, "outside.rdb"), "sensitive")
      File.write(File.join(backup_path, "manifest.json"), JSON.generate(
        name: "backup_full_test", type: :full, files: ["../outside.rdb"]
      ))

      backup = RubyDB::Backup::Backup.new(Object.new, backup_dir: dir)
      restore = RubyDB::Backup::Restore.new(nil, backup_dir: dir)

      expect(backup.verify_backup(backup_path)[:success]).to be(false)
      expect(restore.restore(backup_path, destination: destination)[:success]).to be(false)
      expect(File.exist?(File.join(destination, "outside.rdb"))).to be(false)
    end
  end
end
