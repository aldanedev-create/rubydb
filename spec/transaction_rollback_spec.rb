# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "transaction rollback before-images" do
  it "restores updated and deleted rows" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      columns = [
        RubyDB::Catalog::Column.new("id", :integer, primary_key: true),
        RubyDB::Catalog::Column.new("name", :text)
      ]
      engine.create_table("users", columns)
      first_row_id = engine.insert_row("users", columns, { "id" => 1, "name" => "alice" })
      second_row_id = engine.insert_row("users", columns, { "id" => 2, "name" => "bob" })
      expect([first_row_id, second_row_id]).to all(be_a(Integer))

      engine.begin_transaction
      expect(engine.update_row("users", first_row_id, { "name" => "changed" })).to be(true)
      expect(engine.rollback_transaction).to be(true)

      rows = engine.select_rows("users", columns, visibility_check: false)
      expect(rows.map { |row| [row["id"] || row[:id], row["name"] || row[:name]] })
        .to include([1, "alice"], [2, "bob"])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "restores a deleted row" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer, primary_key: true)]
      engine.create_table("users", columns)
      row_id = engine.insert_row("users", columns, { "id" => 1 })

      engine.begin_transaction
      expect(engine.delete_row("users", row_id, visibility_check: false)).to be(true)
      expect(engine.rollback_transaction).to be(true)

      expect(engine.select_rows("users", columns, visibility_check: false).map { |row| row["id"] }).to eq([1])
    ensure
      engine&.close if engine&.open?
    end
  end
end
