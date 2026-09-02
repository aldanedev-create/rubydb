# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Concurrency::DeadlockDetector do
  it "initializes the concurrency mutex without recursive construction" do
    mutex = RubyDB::Concurrency::Mutex.new("test")
    expect(mutex.synchronize { :ok }).to eq(:ok)
    expect(mutex.locked?).to be(false)
  end

  it "delegates victim rollback to the transaction manager" do
    calls = []
    transaction = RubyDB::Transactions::Transaction.new(id: 9)
    manager = Object.new
    manager.define_singleton_method(:get_transaction) { |id| calls << [:get, id]; transaction }
    manager.define_singleton_method(:rollback_transaction) { |txn| calls << [:rollback, txn.id]; true }
    detector = described_class.new(transaction_manager: manager)
    victim = { id: 9, locks: 1 }

    detector.abort_victim(victim)

    expect(calls).to eq([[:get, 9], [:rollback, 9]])
    expect(victim[:aborted]).to be(true)
  end

  it "counts each resolved deadlock exactly once" do
    manager = RubyDB::Transactions::TransactionManager.new(nil)
    detector = manager
    first = instance_double(RubyDB::Transactions::Transaction, priority: 0)
    second = instance_double(RubyDB::Transactions::Transaction, priority: 1)
    allow(detector).to receive(:build_wait_for_graph).and_return({ first => [second], second => [first] })
    allow(detector).to receive(:rollback_transaction).and_return(true)

    expect(detector.detect_deadlock).to be(true)
    expect(detector.stats[:deadlocks_detected]).to eq(1)
    expect(detector.stats[:deadlocks_resolved]).to eq(1)
  end
end
