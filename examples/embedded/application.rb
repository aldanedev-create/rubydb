# frozen_string_literal: true

# A small Ruby application using the embedded engine directly.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-embedded") do |directory|
  database_path = File.join(directory, "application.rdb")
  columns = [
    RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false),
    RubyDB::Catalog::Column.new(:name, :text, null: false)
  ]

  engine = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
  begin
    engine.create_table(:greetings, columns)
    engine.insert_row(:greetings, columns, { id: 1, name: "RubyDB" })
    puts engine.select_rows(:greetings, columns).inspect
    engine.close
    engine = nil
  ensure
    engine&.close
  end

  reopened = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
  begin
    row = reopened.select_rows(:greetings, reopened.table_columns(:greetings)).first
    name = row && (row[:name] || row["name"])
    raise "embedded row was not durable: #{row.inspect}" unless name == "RubyDB"
    puts "Embedded application persisted and reopened successfully"
  ensure
    reopened.close
  end
end
