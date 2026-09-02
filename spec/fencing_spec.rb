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
end
