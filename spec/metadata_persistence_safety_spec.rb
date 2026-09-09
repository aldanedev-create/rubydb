# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "table metadata persistence" do
  let(:columns) { [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)] }

  it "fails closed for malformed persisted metadata and releases database ownership" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "corrupt.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      engine.create_table(:events, columns)
      engine.close
      engine = nil
      File.binwrite("#{path}.metadata", "{not-json")

      expect { RubyDB::Storage::Engine.new(path, auto_cleanup: false) }
        .to raise_error(RubyDB::CorruptionError, /Unable to load table metadata/)

      lock = RubyDB::Storage::DatabaseLock.new(path)
      expect(lock.acquire!).to be(true)
    ensure
      lock&.release
      engine&.close if engine&.open?
    end
  end

  it "surfaces metadata publish errors without exposing an uncommitted schema" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry.rdb")
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      metadata_path = "#{path}.metadata"
      fail_publish = true
      allow(File).to receive(:rename).and_wrap_original do |original, source, destination|
        raise Errno::EIO, "simulated metadata failure" if fail_publish && destination == metadata_path

        original.call(source, destination)
      end

      expect { engine.create_table(:events, columns) }
        .to raise_error(RubyDB::StorageError, /Unable to persist table metadata/)
      expect(Dir.glob("#{metadata_path}.tmp-*")).to be_empty
      expect(engine.table_exists?(:events)).to be(false)

      fail_publish = false
      expect(engine.create_table(:events, columns)).to be(true)
      engine.close
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      expect(engine.table_exists?(:events)).to be(true)
    ensure
      engine&.close if engine&.open?
    end
  end
end
