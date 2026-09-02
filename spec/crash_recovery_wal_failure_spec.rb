# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Recovery::CrashRecovery do
  it "fails closed when the WAL cannot be read" do
    wal = Object.new
    wal.define_singleton_method(:read_all) { raise "unreadable WAL" }
    recovery = described_class.new(Object.new, wal)

    expect { recovery.recover }.to raise_error("unreadable WAL")
    expect(recovery.stats[:corrupted_records]).to eq(1)
  end
end
