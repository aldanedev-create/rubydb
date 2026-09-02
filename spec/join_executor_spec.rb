# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Execution::JoinExecutor do
  let(:executor) { described_class.new(nil) }

  it "hash joins equi-join rows without using object identity" do
    condition = RubyDB::Execution::Predicate::Comparison.new(
      RubyDB::Execution::Expression::Column.new("id"),
      RubyDB::Execution::Expression::Column.new("user_id"),
      :eq
    )
    left = [{ "id" => 1 }, { "id" => 2 }]
    right = [{ "user_id" => 2 }, { "user_id" => 3 }]

    result = executor.hash_join(left, right, condition)

    expect(result.map { |row| [row["_left_id"], row["_right_user_id"]] }).to eq([[2, 2]])
  end

  it "falls back to nested-loop evaluation for non-equi predicates" do
    condition = RubyDB::Execution::Predicate::Comparison.new(
      RubyDB::Execution::Expression::Column.new("id"),
      RubyDB::Execution::Expression::Literal.new(1),
      :gt
    )

    result = executor.hash_join([{ "id" => 2 }], [{ "value" => "x" }], condition)

    expect(result.size).to eq(1)
  end

  it "uses the hash path automatically for inner equi-joins" do
    condition = RubyDB::Execution::Predicate::Comparison.new(
      RubyDB::Execution::Expression::Column.new("id"),
      RubyDB::Execution::Expression::Column.new("user_id"),
      :eq
    )
    allow(executor).to receive(:hash_join).and_call_original

    executor.inner_join([{ "id" => 7 }], [{ "user_id" => 7 }], condition)

    expect(executor).to have_received(:hash_join).once
  end
end
