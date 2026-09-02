# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Migrations::MigrationLock do
  it "serializes migration owners across lock instances" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      path = File.join(dir, "migration.lock")
      first = described_class.new(engine, lock_path: path)
      second = described_class.new(engine, lock_path: path)

      expect(first.acquire_lock).to be(true)
      expect(second.acquire_lock).to be(false)
      expect(first.stats[:lock_acquired]).to be(true)
      expect(first.release_lock).to be(true)
      expect(second.acquire_lock).to be(true)
      second.release_lock
      engine.close
    ensure
      engine&.close
    end
  end
end
