# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Replication::ReplicationLog do
  it "persists ordered transaction envelopes and filters by LSN" do
    Dir.mktmpdir do |dir|
      log = described_class.new(nil, log_dir: dir)
      log.log_transaction({ id: "tx-1", operation: "insert", table: "users" }, 10)
      log.log_transaction({ id: "tx-2", operation: "update", table: "users" }, 20)

      entries = log.read_transactions(11, 20)
      expect(entries.size).to eq(1)
      expect(entries.first[:lsn]).to eq(20)
      expect(entries.first[:data][:id]).to eq("tx-2")
      expect(log.get_last_lsn).to eq(20)
      expect(log.stats[:transactions_logged]).to eq(2)
    ensure
      log&.close if log.respond_to?(:close)
    end
  end
end
