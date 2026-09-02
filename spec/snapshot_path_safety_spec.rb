# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Backup::Snapshot do
  it "rejects snapshot names that escape the snapshot directory" do
    Dir.mktmpdir do |dir|
      snapshot = described_class.new(Object.new, snapshot_dir: File.join(dir, "snapshots"))

      expect(snapshot.create_snapshot("../outside")[:success]).to be(false)
      expect(snapshot.restore_snapshot("../outside")[:success]).to be(false)
      expect(snapshot.delete_snapshot("../outside")[:success]).to be(false)
    end
  end
end
