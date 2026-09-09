# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "production soak harness" do
  it "validates traffic, deadlines, cancellation, capacity, and deadlocks" do
    script = File.expand_path("../benchmarks/production_soak.rb", __dir__)
    stdout, stderr, status = Open3.capture3(
      {
        "RUBYDB_PRODUCTION_SOAK_CLIENTS" => "2",
        "RUBYDB_PRODUCTION_SOAK_OPERATIONS" => "8",
        "RUBYDB_PRODUCTION_SOAK_CANCEL_ROWS" => "50000"
      },
      RbConfig.ruby, script
    )

    expect(status).to be_success, "production soak failed: #{stderr}\n#{stdout}"
    result = JSON.parse(stdout.lines.last, symbolize_names: true)
    expect(result).to include(
      success: true,
      clients: 2,
      operations_per_client: 8,
      durable_rows: 16,
      deadline_rejected: true,
      cancellation_confirmed: true
    )
    expect(result[:connection_rejections]).to be >= 1
    expect(result[:deadlocks_detected]).to be >= 1
  end
end
