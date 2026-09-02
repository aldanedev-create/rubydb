# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Replication::Primary do
  it "persists replication slot acknowledgements across primary restarts" do
    Dir.mktmpdir do |dir|
      engine = Struct.new(:path).new(File.join(dir, "db.rdb"))
      log_dir = File.join(dir, "log")
      primary = described_class.new(engine, log_dir: log_dir)
      slot = primary.send(:create_replication_slot, "replica_a")
      slot.advance(42)
      primary.send(:persist_slots)

      restarted = described_class.new(engine, log_dir: File.join(dir, "log-restarted"))
      restored = restarted.replication_slots.fetch("replica_a")
      expect(restored.confirmed_lsn).to eq(42)
    end
  end
end
