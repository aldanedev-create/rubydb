# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Backup do
  it "rejects backup deletion names that escape the backup directory" do
    Dir.mktmpdir do |dir|
      backup_dir = File.join(dir, "backups")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "keep.txt"), "do not delete")

      backup = described_class.new(Object.new, backup_dir: backup_dir)

      expect(backup.delete_backup("../outside")[:success]).to be(false)
      expect(File.exist?(File.join(outside, "keep.txt"))).to be(true)
    end
  end
end
