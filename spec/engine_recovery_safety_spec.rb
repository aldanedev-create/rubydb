# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Storage::Engine do
  it "refuses startup and releases ownership when crash recovery fails" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "recovery.rdb")
      wal_dir = "#{path}.wal"
      FileUtils.mkdir_p(wal_dir)
      File.binwrite(File.join(wal_dir, "recovery-trigger.log"), "invalid")

      allow_any_instance_of(RubyDB::Recovery::CrashRecovery).to receive(:recover)
        .and_return(success: false, error: "corrupt WAL")

      expect do
        described_class.new(path, auto_cleanup: false)
      end.to raise_error(RubyDB::RecoveryError, /Crash recovery failed.*corrupt WAL/)

      lock = RubyDB::Storage::DatabaseLock.new(path)
      expect(lock.acquire!).to be(true)
      lock.release
    end
  end
end
