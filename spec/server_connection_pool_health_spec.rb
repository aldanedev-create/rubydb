# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Server::ConnectionPool do
  it "does not report a stopped or closed-connection pool as healthy" do
    pool = described_class.allocate
    pool.instance_variable_set(:@lock, Monitor.new)
    pool.instance_variable_set(:@running, false)
    pool.instance_variable_set(:@connections, {})
    expect(pool.healthy?).to be(false)

    pool.instance_variable_set(:@running, true)
    closed = Struct.new(:closed?).new(true)
    pool.instance_variable_set(:@connections, { 1 => closed })
    expect(pool.healthy?).to be(false)
  end
end
