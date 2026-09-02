# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Prometheus metrics export" do
  it "renders counters, gauges, and escaped labels" do
    metrics = RubyDB::Monitoring::Metrics.new(auto_flush: false)
    metrics.increment("query.count", { endpoint: 'read"path' }, 2)
    metrics.set_gauge("connections", {}, 3)

    output = metrics.to_prometheus

    expect(output).to include("rubydb_query_count{endpoint=\"read\\\"path\"} 2")
    expect(output).to include("rubydb_connections 3")
  end
end
