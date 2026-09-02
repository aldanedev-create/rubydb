# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Branching::CopyOnWrite do
  it "rejects names and file paths that escape the copy-on-write root" do
    Dir.mktmpdir do |dir|
      cow = described_class.new(nil, cow_dir: File.join(dir, "cow"))
      outside = File.join(dir, "outside.txt")

      expect(cow.write_file("../branch", "row.txt", "bad")[:success]).to be(false)
      expect(cow.write_file("main", "../outside.txt", "bad")[:success]).to be(false)
      expect(cow.snapshot("../branch", "snapshot")[:success]).to be(false)
      expect(cow.restore_snapshot("../snapshot", "main")[:success]).to be(false)
      expect(File.exist?(outside)).to be(false)
    end
  end

  it "copies nested files using paths relative to the configured base directory" do
    Dir.mktmpdir do |dir|
      base = File.join(dir, "base")
      FileUtils.mkdir_p(File.join(base, "nested"))
      File.write(File.join(base, "nested", "row.txt"), "value")
      cow = described_class.new(nil, cow_dir: File.join(dir, "cow"))

      result = cow.create_cow("main", base)

      expect(result).to include(success: true, file_count: 1)
      expect(cow.read_file("main", "nested/row.txt")).to eq("value")
    end
  end
end
