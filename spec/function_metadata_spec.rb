# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Functions::Function do
  it "preserves an explicitly unsafe parallel flag" do
    function = described_class.new("external", :system, parallel_safe: false)

    expect(function.to_hash[:parallel_safe]).to be(false)
  end

  it "enforces an explicit zero-argument maximum" do
    function = described_class.new("no_args", :system, max_args: 0)

    expect { function.validate_args([:unexpected]) }.to raise_error(ArgumentError, /at most 0/)
    expect(function.validate_args([])).to be(true)
  end
end
