# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Archive do
  it "encrypts, restores, and verifies an archive payload" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "backup_full_test")
      archive_dir = File.join(dir, "archives")
      restore_dir = File.join(dir, "restored")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "payload.txt"), "durable backup payload")

      archive = described_class.new(
        archive_dir: archive_dir, compression: true,
        encryption: true, encryption_key: "correct horse battery staple"
      )
      created = archive.archive_backup(source)
      expect(created[:success]).to be(true)
      expect(created[:archive_path]).to end_with(".gz.enc")

      restored = archive.restore_archive(created[:archive_path], restore_dir)
      expect(restored[:success]).to be(true)
      expect(File.read(File.join(restore_dir, "backup_full_test", "payload.txt"))).to eq("durable backup payload")
    end
  end
end
