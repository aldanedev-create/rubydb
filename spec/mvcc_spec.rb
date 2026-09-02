# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "RubyDB MVCC visibility" do
  it "keeps visibility metadata isolated per database path" do
    Dir.mktmpdir do |dir|
      first_path = File.join(dir, "first.visibility")
      second_path = File.join(dir, "second.visibility")

      first = RubyDB::Storage::VisibilityMap.new(nil, visibility_path: first_path, auto_vacuum: false)
      second = RubyDB::Storage::VisibilityMap.new(nil, visibility_path: second_path, auto_vacuum: false)
      first.mark_visible(11, 0)
      first.flush

      expect(File).to exist(first_path)
      expect(File).not_to exist(second_path)
      expect(second.visibility_info).to be_empty

      reopened = RubyDB::Storage::VisibilityMap.new(nil, visibility_path: first_path, auto_vacuum: false)
      expect(reopened.visibility_info[11][:state]).to eq(:visible)
    end
  end

  it "generates distinct transaction IDs for independent engine sessions" do
    Dir.mktmpdir do |dir|
      first = RubyDB::Storage::Engine.new(File.join(dir, "first.db"), auto_vacuum: false)
      second = RubyDB::Storage::Engine.new(File.join(dir, "second.db"), auto_vacuum: false)

      expect(first.begin_transaction).not_to eq(second.begin_transaction)
    ensure
      first&.rollback_transaction
      second&.rollback_transaction
      first&.close
      second&.close
    end
  end

  it "persists committed version chains across restart" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.json")
      store = RubyDB::MVCC::VersionStore.new(persistence_path: path)
      version = store.create_version(7, { name: "first" }, 1)
      store.commit_version(version, 1)
      store.persist

      reopened = RubyDB::MVCC::VersionStore.new(persistence_path: path)
      latest = reopened.get_latest_version(7)
      expect(latest.data).to eq(name: "first")
      expect(latest.is_committed).to be(true)
    end
  end

  it "retains and traverses the complete visibility version chain" do
    visibility = RubyDB::Storage::VisibilityMap.new(nil, auto_vacuum: false)
    visibility.mark_visible(12, 0, 1)
    visibility.mark_hidden(12, 2)
    visibility.mark_visible(12, 3)

    expect(visibility.row_history(12).map { |info| info[:version] }).to eq([1, 2, 3])
    expect(visibility.row_versions(12).map { |info| info[:version] }).to eq([3, 2, 1])
  end

  it "vacuum removes only history older than the active safe point" do
    store = RubyDB::MVCC::VersionStore.new
    first = store.create_version(7, { name: "first" }, 1)
    store.commit_version(first, 1)
    second = store.create_version(7, { name: "second" }, 2)
    store.commit_version(second, 2)
    active = store.create_version(7, { name: "active" }, 3)

    expect(store.vacuum(min_active_transaction_id: 3)).to eq(1)
    expect(store.get_all_versions(7).map(&:data)).to eq([{ name: "second" }, { name: "active" }])
    expect(store.get_version(active.version_id)).to be(active)
  end

  it "uses a snapshot to hide versions committed after the snapshot" do
    old = RubyDB::MVCC::Version.new(7, { name: "old" }, 1)
    old.commit(1)
    snapshot = RubyDB::MVCC::Snapshot.new(2, [2], [1])
    newer = RubyDB::MVCC::Version.new(7, { name: "new" }, 3)
    newer.commit(3)

    expect(snapshot.visible?(old, 2)).to be(true)
    expect(snapshot.visible?(newer, 2)).to be(false)
  end

  it "keeps a row visible to a snapshot after a later committed delete" do
    store = RubyDB::MVCC::VersionStore.new
    first = store.create_version(7, { name: "before" }, 1)
    store.commit_version(first, 1)
    snapshot = RubyDB::MVCC::Snapshot.new(2, [], [1])
    deleted = store.create_version(7, { name: "before", _deleted: true }, 3)
    deleted.mark_deleted
    store.commit_version(deleted, 3)

    expect(store.get_latest_version(7, 2, snapshot).data).to eq(name: "before")
    expect(store.get_latest_version(7, 4)).to be_nil
  end

  it "does not expose an uncommitted version to another transaction" do
    visibility = RubyDB::Storage::VisibilityMap.new(nil, auto_vacuum: false)
    visibility.register_transaction(1)
    visibility.register_transaction(2)
    visibility.mark_visible(10, 1)

    expect(visibility.is_visible?(10, 1)).to be(true)
    expect(visibility.is_visible?(10, 2)).to be(false)

    visibility.commit_transaction(1)
    expect(visibility.is_visible?(10, 2)).to be(true)
  end

  it "starts a repeatable read transaction with a stable snapshot" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "mvcc.rdb"), auto_vacuum: false)

      transaction_id = engine.begin_transaction(:repeatable_read)
      expect(transaction_id).to be_a(Integer)
      expect(engine.current_transaction[:isolation_level]).to eq(:repeatable_read)
      engine.rollback_transaction

      engine.close
    end
  end

  it "detects a concurrent commit that conflicts with a serializable snapshot" do
    store = RubyDB::MVCC::VersionStore.new
    original = store.create_version(8, { value: 1 }, 1, key: "items\0#{8}")
    store.commit_version(original, 1)
    snapshot = RubyDB::MVCC::Snapshot.new(2, [], [1])
    concurrent = store.create_version(8, { value: 2 }, 3, key: "items\0#{8}")
    store.commit_version(concurrent, 3)

    expect do
      store.validate_serializable!(snapshot, ["items\0#{8}"], [])
    end.to raise_error(RubyDB::DatabaseError, /serialization failure/)
  end

  it "detects a newer write covered by a table predicate" do
    store = RubyDB::MVCC::VersionStore.new
    original = store.create_version(9, { value: 1 }, 1, key: "items\0#{9}")
    store.commit_version(original, 1)
    snapshot = RubyDB::MVCC::Snapshot.new(2, [], [1])
    concurrent = store.create_version(10, { value: 2 }, 3, key: "items\0#{10}")
    store.commit_version(concurrent, 3)

    expect do
      store.validate_serializable!(snapshot, [], [], read_predicates: ["items\0"])
    end.to raise_error(RubyDB::DatabaseError, /serialization failure/)
  end

  it "rejects unsupported isolation levels" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "serializable.rdb"), auto_vacuum: false)
      expect { engine.begin_transaction(:snapshot) }.to raise_error(RubyDB::DatabaseError, /not supported yet/)
      engine.close
    end
  end
end
