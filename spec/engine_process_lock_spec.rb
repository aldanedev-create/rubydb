# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "embedded database process ownership" do
  it "does not let a rejected engine release the current owner's lock" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "owned.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      2.times do
        expect { RubyDB::Storage::Engine.new(path) }.to raise_error(RubyDB::DatabaseError, /already open/)
      end
      expect(child_open_status(path)).to eq(23)
    ensure
      engine&.close
    end
  end

  it "releases ownership when initialization fails" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "invalid.rdb")
      File.binwrite(path, "invalid database")
      2.times do
        expect { RubyDB::Storage::Engine.new(path) }.to raise_error(RubyDB::StorageError)
      end
      lock = RubyDB::Storage::DatabaseLock.new(path)
      expect(lock.acquire!).to be(true)
    ensure
      lock&.release
    end
  end

  it "releases the OS lock after a process exits without cleanup" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "crashed.rdb")
      library = File.expand_path("../lib", __dir__)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{library.inspect})
        require "rubydb"
        lock = RubyDB::Storage::DatabaseLock.new(#{path.inspect})
        lock.acquire!
        exit! 0
      RUBY
      _, error, status = Open3.capture3(RbConfig.ruby, "-e", script)
      expect(status.success?).to be(true), error
      expect(child_open_status(path)).to eq(0)
    end
  end

  def child_open_status(path)
    library = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{library.inspect})
      require "rubydb"
      begin
        engine = RubyDB::Storage::Engine.new(#{path.inspect}, auto_cleanup: false, auto_vacuum: false)
        engine.close
        exit 0
      rescue RubyDB::DatabaseError
        exit 23
      end
    RUBY
    _output, _error, status = Open3.capture3(RbConfig.ruby, "-e", script)
    status.exitstatus
  end

  it "rejects a second process while the owner is open and permits reopen after close" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "owned.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)

      expect(child_open_status(path)).to eq(23)

      engine.close
      engine = nil
      expect(child_open_status(path)).to eq(0)
    ensure
      engine&.close if engine&.open?
    end
  end
end
