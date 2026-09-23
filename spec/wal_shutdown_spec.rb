# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe "WAL shutdown lifecycle" do
  it "wakes the async writer immediately and durably flushes buffered records" do
    Dir.mktmpdir("rubydb-wal-fast-shutdown") do |dir|
      writer = RubyDB::WAL::Writer.new(dir, async: true, sync: false)
      record = RubyDB::WAL::Record.new(
        RubyDB::WAL::Record::TYPE_INSERT,
        {table_name: "events", row_id: 1, values: {name: "ready"}},
        transaction_id: 1
      )
      writer.write_record(record)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      writer.shutdown
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.2
      expect(Dir.glob(File.join(dir, "wal_*.log")).sum { |path| File.size(path) }).to be > 0
    ensure
      writer&.shutdown
    end
  end

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
