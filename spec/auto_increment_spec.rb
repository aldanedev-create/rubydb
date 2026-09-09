# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "integer primary key allocation" do
  it "allocates omitted primary keys and continues after deletes" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "ids.rdb"), auto_vacuum: false)
      engine.create_table("items", [
        RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new("name", :text, null: false)
      ])

      first = engine.insert_row("items", engine.table_columns("items"), { name: "first" })
      engine.delete_row("items", first)
      second = engine.insert_row("items", engine.table_columns("items"), { name: "second" })

      expect([first, second]).to eq([1, 2])
    ensure
      engine&.close
    end
  end
end
