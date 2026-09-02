# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Branching::BranchManager do
  it "rejects branch names that could escape the branch directory" do
    Dir.mktmpdir do |dir|
      engine = instance_double("Engine", respond_to?: false)
      manager = described_class.new(engine, branch_dir: File.join(dir, "branches"))

      result = manager.create_branch("../outside", from_lsn: 0)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq("Invalid branch name")
    end
  end
end
