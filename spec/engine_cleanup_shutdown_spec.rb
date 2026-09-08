# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Storage::Engine do
  it "does not block shutdown when closed immediately after startup" do
    Dir.mktmpdir do |dir|
      engine = described_class.new(File.join(dir, "immediate-close.rdb"), cleanup_interval: 3600)

      expect { engine.close }.not_to raise_error
      expect(engine.open?).to be(false)
    end
  end

  it "stops background maintenance before closing storage" do
    Dir.mktmpdir do |dir|
      engine = described_class.new(
        File.join(dir, "cleanup.rdb"),
        auto_cleanup: true,
        cleanup_interval: 60,
        auto_vacuum: false
      )
      cleanup_thread = engine.instance_variable_get(:@cleanup_thread)

      expect(cleanup_thread).to be_alive
      expect(engine.close).to be(true)
      expect(cleanup_thread).not_to be_alive
    ensure
      engine&.close if engine&.open?
    end
  end
end
