# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"

RSpec.describe "multi-process server workload" do
  it "runs independent client processes and verifies durable rows" do
    script = File.expand_path("../benchmarks/multiprocess_server_workload.rb", __dir__)
    output, error, status = Open3.capture3(
      { "RUBYDB_SERVER_WORKLOAD_PROCESSES" => "2", "RUBYDB_SERVER_WORKLOAD_OPERATIONS" => "8" },
      RbConfig.ruby, script
    )

    expect(status).to be_success, "#{error}\n#{output}"
    result = JSON.parse(output.lines.last, symbolize_names: true)
    expect(result).to include(processes: 2, operations_per_process: 8, durable_rows: 16)
    expect(result.fetch(:workers).size).to eq(2)
  end

  it "fails bounded child supervision without leaving workers behind" do
    script = File.expand_path("../benchmarks/multiprocess_server_workload.rb", __dir__)
    output, error, status = Open3.capture3(
      {
        "RUBYDB_SERVER_WORKLOAD_PROCESSES" => "2",
        "RUBYDB_SERVER_WORKLOAD_OPERATIONS" => "8",
        "RUBYDB_SERVER_WORKLOAD_CHILD_TIMEOUT" => "0.001"
      },
      RbConfig.ruby, script
    )

    expect(status).not_to be_success
    expect("#{error}\n#{output}").to include("exceeded 0.001 seconds")
  end
end
