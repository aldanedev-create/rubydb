# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "network partition failover drill" do
  it "models a live TCP partition, catch-up, fencing, and promotion" do
    script = File.expand_path("../scripts/replication_network_failover_drill", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)

    expect(status).to be_success, "network failover drill failed: #{stderr}\n#{stdout}"
    result = JSON.parse(stdout, symbolize_names: true)
    expect(result).to include(
      success: true,
      network_partition: true,
      partitioned_primary_stayed_running: true,
      replica_caught_up_after_heal: true,
      stale_primary_rejected: true,
      promoted_rows: [1, 2, 3]
    )
  end
end
