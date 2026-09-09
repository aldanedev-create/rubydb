# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "replication fencing" do
  it "rejects writes from a stale primary after a newer lease is acquired" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cluster.fence")
      first = RubyDB::Replication::FencingLease.new(path, "node-a").acquire!
      second = RubyDB::Replication::FencingLease.new(path, "node-b").acquire!

      expect(first.valid?).to be(false)
      expect(second.valid?).to be(true)
      expect { first.assert_valid! }.to raise_error(RubyDB::ReplicationError, /stale/)
      expect(second.epoch).to eq(2)
    end
  end

  it "blocks stale primary engine mutations before they commit" do
    Dir.mktmpdir("rubydb-fenced-writes") do |dir|
      first_engine = RubyDB::Storage::Engine.new(File.join(dir, "first.rdb"), auto_cleanup: false, auto_vacuum: false)
      second_engine = RubyDB::Storage::Engine.new(File.join(dir, "second.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      first_engine.create_table(:events, columns)
      second_engine.create_table(:events, columns)
      fence_path = File.join(dir, "shared.fence")
      first = RubyDB::Replication::Primary.new(first_engine, fence_path: fence_path, log_dir: File.join(dir, "first-log"))
      second = RubyDB::Replication::Primary.new(second_engine, fence_path: fence_path, log_dir: File.join(dir, "second-log"))

      expect { first_engine.insert_row(:events, columns, id: 1) }
        .to raise_error(RubyDB::ReplicationError, /stale/)
      expect { second_engine.insert_row(:events, columns, id: 2) }.not_to raise_error
    ensure
      first&.stop
      second&.stop
      first_engine&.close if first_engine&.open?
      second_engine&.close if second_engine&.open?
    end
  end
end
