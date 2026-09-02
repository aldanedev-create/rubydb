# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Snapshot do
  it "creates a manifest-verified snapshot and rejects tampering" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer)]
      engine.create_table("items", columns)
      engine.insert_row("items", columns, { "id" => 1 })
      snapshots = described_class.new(engine, snapshot_dir: File.join(dir, "snapshots"))

      result = snapshots.create_snapshot("snap_1")
      expect(result[:success]).to be(true)

      data_file = Dir.glob(File.join(dir, "snapshots", "snap_1", "*.rdb")).first
      File.open(data_file, "ab") { |file| file.write("tampered") }
      restored = snapshots.restore_snapshot("snap_1")
      expect(restored[:success]).to be(false)
      expect(restored[:error]).to include("checksum")

      engine.close
    end
  end
end
