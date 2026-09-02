# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Migrations::Migration do
  it "serializes supported migration operations into executable SQL" do
    migration = described_class.new("1", "users")
    migration.up do |engine|
      engine.create_table("users") do |table|
        table.column("id", :integer, primary_key: true, null: false)
        table.column("active", :boolean, default: false)
      end
      engine.add_index("users", :active, unique: true)
    end

    expect(migration.to_sql).to eq(<<~SQL.chomp)
      CREATE TABLE "users" ("id" INTEGER PRIMARY KEY NOT NULL, "active" BOOLEAN DEFAULT FALSE);
      CREATE UNIQUE INDEX "idx_users_active" ON "users" ("active");
    SQL
  end

  it "fails explicitly for operations that cannot be serialized" do
    migration = described_class.new("1", "dynamic")
    migration.up { |engine| engine.custom_runtime_operation }

    expect { migration.to_sql }.to raise_error(ArgumentError, /custom_runtime_operation/)
  end
end
