# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyDB entrypoint" do
  it "loads the library via the top-level require" do
    expect { require "rubydb" }.not_to raise_error
    expect(RubyDB::VERSION).to be_a(String)
    expect(RubyDB::Storage::PageHeader::SIZE).to be > 0
  end

  it "keeps the storage page header round-trippable" do
    header = RubyDB::Storage::PageHeader.new
    round_tripped = RubyDB::Storage::PageHeader.deserialize(header.serialize)

    expect(round_tripped.page_number).to eq(header.page_number)
    expect(round_tripped.page_size).to eq(header.page_size)
    expect(round_tripped.page_type).to eq(header.page_type)
    expect(round_tripped.data_end).to eq(header.data_end)
  end

  it "persists and reloads a table across a storage reopen" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "db.rdb")
      engine = RubyDB::Storage::Engine.new(path)
      columns = [
        RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
        RubyDB::Catalog::Column.new(:name, :text, null: false)
      ]

      engine.create_table(:users, columns)
      engine.insert_row(:users, columns, [1, "alice"])
      engine.close

      reopened = RubyDB::Storage::Engine.new(path)
      expect(reopened.list_tables).to include(:users)
      expect(reopened.select_rows(:users, columns).first[:name]).to eq("alice")
      reopened.close
    end
  end
end
