# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Storage::Engine do
  it "surfaces WAL checkpoint failures during shutdown" do
    Dir.mktmpdir do |dir|
      engine = described_class.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      checkpoint = engine.wal.checkpoint
      allow(checkpoint).to receive(:create_checkpoint).and_raise("checkpoint failed")

      expect { engine.close }.to raise_error("checkpoint failed")
      expect(engine.open?).to be(true)
    ensure
      allow(checkpoint).to receive(:create_checkpoint).and_call_original if checkpoint
      engine&.close if engine&.open?
    end
  end
end
