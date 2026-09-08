# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Replication::Replica do
  it "buffers split replication frames before decoding and acknowledging them" do
    Dir.mktmpdir do |dir|
      engine_class = Struct.new(:path, :applied) do
        def apply_transaction(data)
          self.applied << data
          true
        end
      end
      engine = engine_class.new(File.join(dir, "replica.rdb"), [])
      replica = described_class.new(engine, state_path: File.join(dir, "replica-state.json"))
      frame = JSON.generate(type: "replication_data", data: [{ lsn: 9, data: { operation: "insert" } }]) + "\n"

      replica.send(:process_replication_data, frame[0...12])
      expect(engine.applied).to be_empty

      replica.send(:process_replication_data, frame[12..])
      expect(engine.applied).to eq([{ operation: "insert" }])
      expect(replica.replication_status).to include(last_received_lsn: 9, last_replayed_lsn: 9)
    end
  end

  it "rejects an unterminated replication frame beyond its configured limit" do
    engine = Struct.new(:path).new("replica.rdb")
    replica = described_class.new(engine, state_path: File.join(Dir.tmpdir, "rubydb-replica-limit-#{Process.pid}.json"), max_replication_frame_bytes: 8)

    expect { replica.send(:process_replication_data, "x" * 9) }
      .to raise_error(RubyDB::ReplicationError, /exceeds 8 bytes/)
  end

  it "persists the last replayed LSN only after a successful apply" do
    Dir.mktmpdir do |dir|
      engine_class = Struct.new(:path, :applied) do
        def apply_transaction(data)
          self.applied << data
          true
        end
      end
      engine = engine_class.new(File.join(dir, "replica.rdb"), [])
      state_path = File.join(dir, "replica-state.json")
      replica = described_class.new(engine, state_path: state_path)
      replica.replay_transaction({ operation: "insert" }, 17)

      restarted = described_class.new(engine, state_path: state_path)
      expect(restarted.replication_status[:last_replayed_lsn]).to eq(17)
      expect(restarted.replication_status[:last_received_lsn]).to be_nil
    end
  end

  it "fails closed for corrupt persisted state" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "broken")
      engine = Struct.new(:path).new(File.join(dir, "replica.rdb"))

      expect { described_class.new(engine, state_path: path) }.to raise_error(RubyDB::ReplicationError)
    end
  end
end
