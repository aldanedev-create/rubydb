# frozen_string_literal: true

require "spec_helper"

RSpec.describe "replication failover safety" do
  it "requires a synchronized replica and verifies promotion" do
    replica = instance_double(
      RubyDB::Replication::Replica,
      running?: true,
      config: { node_id: "replica-1" },
      primary_host: "127.0.0.1",
      primary_port: 7433,
      replication_status: {
        state: RubyDB::Replication::Replica::STATE_SYNCED,
        lag_ms: 0,
        last_replayed_lsn: 42
      }
    )
    manager = instance_double(
      RubyDB::Replication::ReplicationManager,
      replica: replica,
      mode: RubyDB::Replication::ReplicationManager::MODE_PRIMARY,
      health_check: { healthy: true }
    )
    allow(manager).to receive(:promote_to_primary).and_return(success: true)

    failover = RubyDB::Replication::Failover.new(manager, trigger: :manual)
    result = failover.send(:execute_failover, "operator test")

    expect(result[:success]).to be(true)
    expect(result[:candidate]).to eq("replica-1")
    expect(failover.stats[:successful_failovers]).to eq(1)
  end

  it "does not select a streaming replica for automatic promotion" do
    replica = instance_double(
      RubyDB::Replication::Replica,
      running?: true,
      config: {},
      replication_status: { state: RubyDB::Replication::Replica::STATE_STREAMING }
    )
    manager = instance_double(RubyDB::Replication::ReplicationManager, replica: replica)
    failover = RubyDB::Replication::Failover.new(manager)

    expect(failover.send(:find_candidate_replicas)).to be_empty
  end
end
