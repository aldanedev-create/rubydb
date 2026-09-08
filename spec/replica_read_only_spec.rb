# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "replica write fencing" do
  it "rejects local writes while permitting replay, then re-enables writes on promotion" do
    Dir.mktmpdir("rubydb-replica-read-only") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "replica.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      engine.create_table(:events, columns)
      replica = RubyDB::Replication::Replica.new(engine, state_path: File.join(dir, "replica-state.json"))

      expect(engine).to be_replication_read_only
      expect { engine.insert_row(:events, columns, id: 1) }
        .to raise_error(RubyDB::ReplicationError, /read-only/)

      replica.replay_transaction(operation: :insert, table: :events, values: { id: 1 }, lsn: 1)
      expect(engine.select_rows(:events, columns)).to include(hash_including(id: 1))

      replica.promote_to_primary
      expect(engine).not_to be_replication_read_only
      expect { engine.insert_row(:events, columns, id: 2) }.not_to raise_error
    ensure
      replica&.stop
      engine&.close if engine&.open?
    end
  end
end
