# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Constraints::Validator do
  let(:constraint) do
    RubyDB::Constraints::CheckConstraint.new(
      "payments",
      "amount > 0",
      name: "positive_amount"
    )
  end

  it "revalidates supplied rows before clearing deferred constraints" do
    validator = described_class.new
    validator.defer_constraint(constraint, "payments", rows: [{ amount: 10 }])

    result = validator.validate_deferred("payments")

    expect(result[:valid]).to be(true)
    expect(result[:constraints_checked]).to eq(["positive_amount"])
    expect(validator.validate_deferred("payments")[:valid]).to be(true)
  end

  it "fails closed when deferred validation has no row source" do
    validator = described_class.new
    validator.defer_constraint(constraint, "payments")

    result = validator.validate_deferred("payments")

    expect(result[:valid]).to be(false)
    expect(result[:errors].first[:error]).to include("requires rows")
    expect(validator.validate_deferred("payments")[:valid]).to be(false)
  end

  it "accepts a row provider for live table validation" do
    validator = described_class.new
    validator.defer_constraint(constraint, "payments", row_provider: -> { [{ amount: 5 }] })

    expect(validator.validate_deferred("payments")[:valid]).to be(true)
  end

  it "collects deferred rows and skips immediate enforcement" do
    validator = described_class.new
    validator.defer_constraint(constraint, "payments")

    result = validator.validate_row({ amount: -1 }, "payments")

    expect(result[:valid]).to be(true)
    expect(validator.validate_deferred("payments")[:valid]).to be(false)
  end
end
