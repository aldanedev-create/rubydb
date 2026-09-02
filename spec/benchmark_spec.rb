# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"

RSpec.describe "benchmark harness" do
  it "runs a deterministic storage workload and emits measurable metrics" do
    script = File.expand_path("../benchmarks/basic_workload.rb", __dir__)
    stdout, stderr, status = Open3.capture3(
      { "RUBYDB_BENCHMARK_ITERATIONS" => "5" },
      RbConfig.ruby, "-Ilib", script
    )

    expect(status).to be_success
    expect(stderr).to eq("")
    metrics = JSON.parse(stdout)
    expect(metrics.fetch("inserted_rows")).to eq(5)
    expect(metrics.fetch("selected_rows")).to eq(25)
    expect(metrics.fetch("insert_rows_per_second")).to be > 0
    expect(metrics.fetch("select_queries_per_second")).to be > 0
    expect(metrics.fetch("database_bytes")).to be > 0
  end
end
