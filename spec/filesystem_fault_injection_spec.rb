# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "filesystem fault injection" do
  def injector_for(operation)
    lambda do |actual, _context|
      raise IOError, "simulated #{operation} failure" if actual == operation
    end
  end

  it "surfaces a failed page write as a storage error" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page-write.rdb")
      manager = RubyDB::Storage::StorageManager.new(path, io_fault_injector: injector_for(:page_write))
      expect { manager.open }.to raise_error(RubyDB::StorageError, /page_write/)
    end
  end

  it "surfaces an interrupted file extension before publishing a page" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "extend.rdb")
      manager = RubyDB::Storage::StorageManager.new(path, io_fault_injector: injector_for(:file_extend))
      manager.open

      expect { manager.allocate_page }.to raise_error(RubyDB::StorageError, /file_extend/)
      expect(manager.file_manager.open?).to be(true)
    ensure
      manager&.close rescue nil
    end
  end

  it "surfaces sync failures instead of reporting a durable flush" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sync.rdb")
      manager = RubyDB::Storage::StorageManager.new(path, io_fault_injector: injector_for(:file_sync))
      manager.open

      expect { manager.flush }.to raise_error(RubyDB::StorageError, /file_sync/)
    ensure
      manager&.file_manager&.close rescue nil
    end
  end
end
