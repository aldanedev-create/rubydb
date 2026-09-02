# frozen_string_literal: true

# A complete embedded RubyDB application. Run from this directory with:
#   ruby app.rb

$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "rubydb"
$stdout.sync = true

database_path = File.expand_path("rubydb_app.rdb", __dir__)
puts "Opening RubyDB database at #{database_path}"
engine = RubyDB::Storage::Engine.new(
  database_path,
  auto_cleanup: false,
  auto_vacuum: false
)
reopened = nil

begin
  columns = [
    RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new(:email, :varchar, null: false, unique: true),
    RubyDB::Catalog::Column.new(:active, :boolean, null: false, default: true)
  ]

  engine.create_table(:accounts, columns) unless engine.table_exists?(:accounts)

  existing = engine.select_rows(:accounts, columns, id: 1)
  engine.insert_row(:accounts, columns, {id: 1, email: "ada@example.test", active: true}) if existing.empty?

  account = engine.select_rows(:accounts, columns, id: 1).first
  raise "RubyDB did not persist the account" unless account && account[:email] == "ada@example.test"

  puts "Closing RubyDB database"
  engine.close
  engine = nil

  puts "Reopening RubyDB database"
  reopened = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
  persisted = reopened.select_rows(:accounts, reopened.table_columns(:accounts), id: 1).first
  active = persisted && (persisted[:active] || persisted["active"])
  raise "RubyDB data was not durable across reopen: #{persisted.inspect}" unless active == true

  puts "RubyDB regular Ruby app passed: #{persisted.inspect}"
ensure
  engine&.close
  reopened&.close
end
