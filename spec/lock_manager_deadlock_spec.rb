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
end
