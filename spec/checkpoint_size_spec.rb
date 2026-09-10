# frozen_string_literal: true

require "spec_helper"

RSpec.describe "WAL checkpoint sizing" do
  it "reports the actual current WAL segment size" do
    segment = instance_double("segment", segment_id: 3, size: 12_345)
    writer = instance_double(
      RubyDB::WAL::Writer,
      current_segment: segment,
      current_lsn: RubyDB::WAL::LSN.new(3, 12_345),
      stats: {buffer_bytes: 0}
    )
    allow(writer).to receive(:flush)
    allow(writer).to receive(:sync)
    allow(writer).to receive(:write_record).and_return(RubyDB::WAL::LSN.new(3, 12_400))
    checkpoint = RubyDB::WAL::Checkpoint.new(writer, min_age: 0)

    expect(checkpoint.create_checkpoint(true)).to be(true)
    expect(checkpoint.stats[:last_checkpoint_size]).to eq(12_345)
  end

  it "fails visibly without publishing checkpoint state when the frame cannot be written" do
    writer = instance_double(
      RubyDB::WAL::Writer,
      current_segment: instance_double("segment", segment_id: 1, size: 100),
      current_lsn: RubyDB::WAL::LSN.new(1, 100),
      stats: {buffer_bytes: 0}
    )
    allow(writer).to receive(:flush)
    allow(writer).to receive(:write_record).and_raise(Errno::ENOSPC, "checkpoint disk full")
    checkpoint = RubyDB::WAL::Checkpoint.new(writer, min_age: 0)

    expect { checkpoint.create_checkpoint(true) }.to raise_error(Errno::ENOSPC, /checkpoint disk full/)
    expect(checkpoint.checkpoint_exists?).to be(false)
    expect(checkpoint.stats).to include(checkpoint_failures: 1, last_error: include("checkpoint disk full"))
  end
end
