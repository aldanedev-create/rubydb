# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Transactions::LockManager do
  it "returns complete wait-for cycles" do
    manager = described_class.new
    graph = { 1 => Set.new([2]), 2 => Set.new([3]), 3 => Set.new([1]) }

    cycles = manager.send(:detect_cycles, graph)

    expect(cycles).to include([1, 2, 3, 1])
  end

  it "rolls back deadlock victims through the transaction manager" do
    calls = []
    transaction = RubyDB::Transactions::Transaction.new(id: 4)
    transaction_manager = Object.new
    transaction_manager.define_singleton_method(:get_transaction) { |id| calls << [:get, id]; transaction }
    transaction_manager.define_singleton_method(:rollback_transaction) { |txn| calls << [:rollback, txn.id]; true }
    manager = described_class.new(transaction_manager: transaction_manager)

    manager.send(:abort_transaction, 4)

    expect(calls).to eq([[:get, 4], [:rollback, 4]])
  end

  it "detects and resolves a real two-transaction lock cycle" do
    manager = described_class.new(lock_timeout: 0.1)
    first = RubyDB::Transactions::Transaction.new(id: "first", priority: 1)
    second = RubyDB::Transactions::Transaction.new(id: "second", priority: 2)
    expect(manager.acquire_lock(first, "items", 1, :exclusive)).to be(true)
    expect(manager.acquire_lock(second, "items", 2, :exclusive)).to be(true)

    ready = Queue.new
    waits = [
      Thread.new do
        ready << true
        manager.acquire_lock(first, "items", 2, :exclusive, 0.1)
      end,
      Thread.new do
        ready << true
        manager.acquire_lock(second, "items", 1, :exclusive, 0.1)
      end
    ]
    2.times { ready.pop }
    waits.each { |thread| expect(thread.join(2)).to be_a(Thread) }

    expect(manager.stats[:deadlocks_detected]).to be >= 1
    expect(manager.stats[:deadlocks_resolved]).to be >= 1
    expect([first.aborted?, second.aborted?].count(true)).to eq(1)
    expect(manager.waiting_transactions).to eq(0)
  ensure
    waits&.each { |thread| thread.kill if thread.alive? }
  end

  it "rolls back the victim when the transaction manager owns the lock manager" do
    manager = RubyDB::Transactions::TransactionManager.new(nil, auto_cleanup: false, recovery: false)
    first = manager.begin_transaction(timeout: 0.1, priority: 1)
    second = manager.begin_transaction(timeout: 0.1, priority: 2)
    expect(manager.acquire_lock(first, "items", 1, :exclusive)).to be(true)
    expect(manager.acquire_lock(second, "items", 2, :exclusive)).to be(true)

    waits = [
      Thread.new { manager.acquire_lock(first, "items", 2, :exclusive) },
      Thread.new { manager.acquire_lock(second, "items", 1, :exclusive) }
    ]
    waits.each { |thread| expect(thread.join(2)).to be_a(Thread) }

    expect(manager.lock_manager.stats[:deadlocks_detected]).to be >= 1
    expect(manager.lock_manager.stats[:deadlocks_resolved]).to be >= 1
    expect([first.aborted?, second.aborted?].count(true)).to eq(1)
  ensure
    waits&.each { |thread| thread.kill if thread.alive? }
    manager&.release_all_locks
  end
end
