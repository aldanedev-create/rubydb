# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "RubyDB recovery resource checks" do
  it "fails closed for unavailable prepared-transaction resources" do
    recovery = RubyDB::Recovery::CrashRecovery.allocate
    record = Struct.new(:data).new({ resources: ["missing-resource.lock"] })

    expect(recovery.send(:can_commit_prepared?, record)).to be(false)
  end

  it "accepts an existing file resource" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "resource.lock")
      File.write(path, "held")
      recovery = RubyDB::Recovery::CrashRecovery.allocate
      record = Struct.new(:data).new({ resources: [{ path: path }] })

      expect(recovery.send(:can_commit_prepared?, record)).to be(true)
    end
  end

  it "fails closed for unavailable WAL prepared-transaction resources" do
    wal = RubyDB::WAL::WAL.allocate
    record = Struct.new(:data).new({ resources: ["missing-resource.lock"] })

    expect(wal.send(:can_commit_prepared?, record)).to be(false)
  end
end
