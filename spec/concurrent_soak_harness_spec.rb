# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"

RSpec.describe "concurrent soak harness" do
  it "repeats concurrent writes and verifies every durable row" do
    environment = {
      "RUBYDB_SOAK_ROUNDS" => "2",
      "RUBYDB_SOAK_THREADS" => "2",
      "RUBYDB_SOAK_OPERATIONS" => "25",
      "RUBYDB_SOAK_PAYLOAD_BYTES" => "16"
    }
    script = File.expand_path("../benchmarks/concurrent_soak.rb", __dir__)
    output, error, status = Open3.capture3(environment, RbConfig.ruby, script)

    expect(status).to be_success, "#{error}\n#{output}"
    result = JSON.parse(output.lines.last, symbolize_names: true)
    expect(result).to include(rounds: 2, total_inserts: 100, durable_rows_verified: 100)
  end
end
