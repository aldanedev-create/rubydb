# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Transactions::LockManager do
  it "allows a waiter to acquire after the holder releases" do
    manager = described_class.new(lock_timeout: 1)
    holder = RubyDB::Transactions::Transaction.new(id: 1)
    waiter = RubyDB::Transactions::Transaction.new(id: 2)
    expect(manager.acquire_lock(holder, "items", 7, :exclusive)).to be(true)

    result = Queue.new
    thread = Thread.new do
      result << manager.acquire_lock(waiter, "items", 7, :exclusive, 1)
    end
    sleep 0.05
    manager.release_locks(holder)
    thread.join

    expect(result.pop).to be(true)
    expect(manager.waiting_transactions).to eq(0)
  end

  it "times out without retaining a stale waiter" do
    manager = described_class.new(lock_timeout: 0.05)
    holder = RubyDB::Transactions::Transaction.new(id: 1)
    waiter = RubyDB::Transactions::Transaction.new(id: 2)
    manager.acquire_lock(holder, "items", 7, :exclusive)

    expect(manager.acquire_lock(waiter, "items", 7, :exclusive, 0.01)).to be(false)
    expect(manager.waiting_transactions).to eq(0)
  end
end
