# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "process-level replication failover drill" do
  it "replays after primary process loss and rejects a fenced stale writer" do
    script = File.expand_path("../scripts/replication_failover_drill", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)

    expect(status).to be_success, "failover drill failed: #{stderr}\n#{stdout}"
    result = JSON.parse(stdout, symbolize_names: true)
    expect(result).to include(
      success: true,
      primary_processes: 3,
      replica_processes: 1,
      stale_write_rejected: true,
      rows_replayed_after_failover: 2
    )
  end
end
