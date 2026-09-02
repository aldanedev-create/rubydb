# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Rails::SchemaStatements do
  let(:adapter) do
    object = Object.new
    object.extend(described_class)
    object.define_singleton_method(:execute) { |sql| (@executed ||= []) << sql }
    object.define_singleton_method(:executed) { @executed || [] }
    object
  end

  it "places CREATE TABLE IF NOT EXISTS in valid SQL order" do
    adapter.create_table("events", if_not_exists: true) do |table|
      table.string("name", null: false)
    end

    expect(adapter.executed.first).to start_with('CREATE TABLE IF NOT EXISTS "events"')
    expect(adapter.executed.first).not_to match(/\) IF NOT EXISTS\z/)
  end

  it "passes remove-timestamps options to both column removals" do
    adapter.remove_timestamps("events", cascade: true)

    expect(adapter.executed).to eq([
      'ALTER TABLE "events" DROP COLUMN "updated_at" CASCADE',
      'ALTER TABLE "events" DROP COLUMN "created_at" CASCADE'
    ])
  end

  it "preserves false defaults and uses conventional foreign-key columns" do
    adapter.add_column("users", "active", :boolean, default: false)
    adapter.add_foreign_key("posts", "users")

    expect(adapter.executed).to include('ALTER TABLE "users" ADD COLUMN "active" BOOLEAN DEFAULT FALSE')
    expect(adapter.executed).to include('ALTER TABLE "posts" ADD CONSTRAINT "fk_posts_to_users" FOREIGN KEY ("user_id") REFERENCES "users" ("id")')
  end

  it "supports the engine's documented block table builder" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "block.rdb"), auto_vacuum: false)
      expect(engine.create_table("events") { |table| table.column("id", :integer, primary_key: true) }).to be(true)
      expect(engine.table_columns("events").map(&:name)).to eq(["id"])
    ensure
      engine&.close if engine&.open?
    end
  end
end
