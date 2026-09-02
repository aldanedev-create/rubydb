# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Monitoring::Metrics do
  it "updates nested counter and gauge operations without deadlocking" do
    metrics = described_class.new(auto_flush: false)

    expect(metrics.increment("queries")).to eq(1)
    expect(metrics.increment("queries", {}, 2)).to eq(3)
    expect(metrics.decrement("queries")).to eq(2)
    expect(metrics.set_gauge("connections", {}, 4)).to eq(4)
    expect(metrics.get("queries")[:value]).to eq(2)
    expect(metrics.get("connections")[:value]).to eq(4)
  end
end
