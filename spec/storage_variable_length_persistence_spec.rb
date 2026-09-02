# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "variable-length row storage" do
  it "preserves a variable-length value before fixed-width columns after reopening" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "variable-length.rdb")
      columns = [
        RubyDB::Catalog::Column.new("id", :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new("name", :varchar, null: false),
        RubyDB::Catalog::Column.new("active", :boolean, null: false)
      ]
      engine = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      engine.create_table("users", columns)
      engine.insert_row("users", columns, { id: 1, name: "Ada Lovelace", active: true })
      engine.close

      reopened = RubyDB::Storage::Engine.new(path, auto_vacuum: false)
      expect(reopened.select_rows("users", reopened.table_columns("users"))).to include(
        hash_including("id" => 1, "name" => "Ada Lovelace", "active" => true)
      )
    ensure
      reopened&.close if reopened&.open?
      engine&.close if engine&.open?
    end
  end
end
