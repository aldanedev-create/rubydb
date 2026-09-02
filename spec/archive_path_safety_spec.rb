# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Archive do
  it "rejects archive deletion names that escape the archive directory" do
    Dir.mktmpdir do |dir|
      archive_dir = File.join(dir, "archive")
      outside = File.join(dir, "outside.tar")
      FileUtils.mkdir_p(archive_dir)
      File.write(outside, "keep")
      archive = described_class.new(archive_dir: archive_dir)

      expect(archive.delete_archive("../outside.tar")[:success]).to be(false)
      expect(File.exist?(outside)).to be(true)
    end
  end

  it "keeps an explicitly supplied compressed archive after restore" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "backup")
      archive_dir = File.join(dir, "archive")
      external_archive = File.join(dir, "external.tar.gz")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "payload.txt"), "payload")
      archive = described_class.new(archive_dir: archive_dir, compression: true)
      created = archive.archive_backup(source)
      FileUtils.cp(created[:archive_path], external_archive)

      result = archive.restore_archive(external_archive, File.join(dir, "restore"))

      expect(result[:success]).to be(true)
      expect(File.file?(external_archive)).to be(true)
    end
  end

  it "rejects tar entries that escape the restore destination" do
    archive = described_class.new
    status = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(["backup/\n../outside.txt\n", "", status])

    expect {
      archive.send(:validate_tar_entries!, "archive.tar", "restore")
    }.to raise_error(/unsafe paths/)
  end
end
