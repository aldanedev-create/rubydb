# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "storage compaction" do
  it "parses engine records and preserves rows through compaction and reopen" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "compact.rdb")
      columns = [
        RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new("body", :text, null: false)
      ]
      engine = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      engine.create_table("items", columns)
      3.times { |id| engine.insert_row("items", columns, [id + 1, "payload-#{id}"]) }

      page_number = engine.instance_variable_get(:@table_pages).fetch("items").first
      result = engine.storage_manager.page_allocator.compact_page(page_number)

      expect(result[:records_compacted]).to eq(3)
      expect(engine.select_rows("items", columns).size).to eq(3)
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_cleanup: false, auto_vacuum: false)
      expect(reopened.select_rows("items", columns).size).to eq(3)
    ensure
      reopened&.close if reopened&.open?
      engine&.close if engine&.open?
    end
  end
end
