# frozen_string_literal: true

require "spec_helper"

RSpec.describe "server metrics requests" do
  it "exposes Prometheus text through the request handler" do
    metrics = RubyDB::Monitoring::Metrics.new(auto_flush: false)
    metrics.increment("queries")
    handler = RubyDB::Server::RequestHandler.new(Object.new, Object.new, metrics: metrics,
                                                  health: Object.new)
    health = handler.instance_variable_get(:@health)
    health.define_singleton_method(:check) { { status: :healthy, checks: {} } }

    response = handler.handle(type: :metrics)

    expect(response[:success]).to be(true)
    expect(response[:data][:format]).to eq("prometheus")
    expect(response[:data][:body]).to include("rubydb_queries 1")
  end
end
