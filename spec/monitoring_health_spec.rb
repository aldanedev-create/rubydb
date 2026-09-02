# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Monitoring::Health do
  let(:engine) do
    Struct.new(:connected?, :storage_available?, :memory_usage, :replication_healthy?,
               :connection_usage, :wal_healthy?).new(true, true, 0.1, true, 0.1, true)
  end

  it "separates liveness from dependency readiness" do
    health = described_class.new(engine, auto_check: false)

    expect(health.liveness).to include(status: :healthy, live: true)
    expect(health.readiness).to include(status: :healthy, ready: true)
  end

  it "reports not ready when a dependency is unhealthy" do
    unhealthy_engine = Struct.new(:connected?, :storage_available?, :memory_usage,
                                  :replication_healthy?, :connection_usage, :wal_healthy?)
                                  .new(true, false, 0.1, true, 0.1, true)
    health = described_class.new(unhealthy_engine, auto_check: false)

    expect(health.liveness[:live]).to be(true)
    expect(health.readiness).to include(status: :unhealthy, ready: false)
  end
end
