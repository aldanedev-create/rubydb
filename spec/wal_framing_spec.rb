# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RubyDB::WAL::WAL do
  it "reads each framed record independently after reopen" do
    Dir.mktmpdir do |dir|
      wal_dir = File.join(dir, ".wal")
      wal = described_class.new(wal_dir, recovery: false, auto_checkpoint: false, async: false)

      3.times do |i|
        wal.write(RubyDB::WAL::Record.new(:insert, { values: [i] }, transaction_id: i))
      end
      wal.shutdown

      reopened = described_class.new(wal_dir, recovery: false, auto_checkpoint: false, async: false)
      records = reopened.read_all

      expect(records.map { |record| record.data[:values] }).to eq([[0], [1], [2]])
      offsets = records.map { |record| record.lsn.offset }
      expect(offsets.first).to eq(0)
      expect(offsets.each_cons(2).all? { |left, right| right > left }).to be(true)
      reopened.shutdown
    end
  end

  it "stops at an incomplete final frame" do
    Dir.mktmpdir do |dir|
      wal_dir = File.join(dir, ".wal")
      wal = described_class.new(wal_dir, recovery: false, auto_checkpoint: false, async: false)
      wal.write(RubyDB::WAL::Record.new(:insert, { values: [1] }))
      wal.shutdown

      path = File.join(wal_dir, "wal_00000001.log")
      File.open(path, "ab") { |file| file.write([100].pack("N") + "partial") }

      reopened = described_class.new(wal_dir, recovery: false, auto_checkpoint: false, async: false)
      expect(reopened.read_all.size).to eq(1)
      reopened.shutdown
    end
  end
end
