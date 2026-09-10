# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "WAL shutdown lifecycle" do
  it "joins the async writer before the WAL directory is removed" do
    Dir.mktmpdir("rubydb-wal-shutdown") do |dir|
      wal_dir = File.join(dir, "wal")
      wal = RubyDB::WAL::WAL.new(
        wal_dir,
        buffer_size: 1,
        sync: false,
        auto_checkpoint: false,
        recovery: false
      )
      wal.write(RubyDB::WAL::Record.new(:insert, {table: "events", row_id: 1}))
      wal.shutdown
      wal = nil

      expect { FileUtils.rm_rf(wal_dir) }.not_to raise_error
    ensure
      wal&.shutdown
    end
  end
end
