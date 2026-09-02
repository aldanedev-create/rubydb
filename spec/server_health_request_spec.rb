# frozen_string_literal: true

require "spec_helper"

RSpec.describe "server health requests" do
  it "exposes liveness and dependency-aware readiness" do
    health = Object.new
    health.define_singleton_method(:liveness) { { status: :healthy, live: true } }
    health.define_singleton_method(:readiness) { { status: :unhealthy, ready: false } }
    health.define_singleton_method(:check) { { status: :unhealthy, checks: {} } }
    handler = RubyDB::Server::RequestHandler.new(Object.new, Object.new, health: health)

    live = handler.handle(type: :liveness)
    ready = handler.handle(type: :readiness)
    expect(live[:success]).to be(true)
    expect(live[:data][:live]).to be(true)
    expect(ready[:data][:ready]).to be(false)
  end
end
