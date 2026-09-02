# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Migrations::MigrationManager do
  FakeDatabase = Struct.new(:engine, :rows, :executed) do
    def execute(sql)
      self.executed << sql
      true
    end

    def query(_sql)
      rows
    end

    def transaction
      yield
    end
  end

  it "applies migrations in version order and records them" do
    database = FakeDatabase.new(Struct.new(:path).new("/tmp/rubydb-test"), [], [])
    first = RubyDB::Migrations::Migration.new("2", "second").up { |engine| engine.instance_variable_set(:@ran, true) }
    second = RubyDB::Migrations::Migration.new("1", "first")

    result = described_class.new(database, migrations: [first, second]).migrate

    expect(result.map(&:version)).to eq(["1", "2"])
    expect(database.executed.grep(/INSERT INTO schema_migrations/).size).to eq(2)
  end

  it "rejects a lock that cannot be acquired" do
    database = FakeDatabase.new(Struct.new(:path).new("/tmp/rubydb-test"), [], [])
    manager = described_class.new(database, migrations: [])
    allow_any_instance_of(RubyDB::Migrations::MigrationLock).to receive(:acquire_lock).and_return(false)

    expect { manager.migrate }.to raise_error(RubyDB::Migrations::MigrationError)
  end

  it "filters numeric target versions numerically rather than lexicographically" do
    database = FakeDatabase.new(Struct.new(:path).new("/tmp/rubydb-test"), [], [])
    migrations = %w[1 2 10].map do |version|
      RubyDB::Migrations::Migration.new(version, "migration_#{version}")
    end

    result = described_class.new(database, migrations: migrations, version: "2").migrate

    expect(result.map(&:version)).to eq(%w[1 2])
  end
end

RSpec.describe RubyDB::Migrations::SchemaDiff do
  it "generates migration code without deadlocking or referencing caller locals" do
    diff = described_class.new(nil)
    result = diff.generate_migration({"users" => {"id" => "INTEGER"}}, {"users" => {"id" => "BIGINT", "name" => "TEXT"}})

    expect(result[:code]).not_to include("target_schema[")
    expect(result[:code]).to include("engine.add_column('users', 'name', 'TEXT')")
  end
end
