# frozen_string_literal: true

# Create a durable embedded database. Pass a path to keep the database, or
# let the example use a local file next to this script.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "fileutils"
require "rubydb"

database_path = ARGV.first || File.expand_path("rubydb_basic.rdb", __dir__)
FileUtils.mkdir_p(File.dirname(database_path))
engine = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
connection = RubyDB::Rails::Connection.new(engine: engine)
connection.connect

begin
  connection.execute(<<~SQL)
    CREATE TABLE IF NOT EXISTS app_info (
      id INTEGER PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      environment VARCHAR(32) NOT NULL
    )
  SQL
  connection.execute(<<~SQL)
    INSERT INTO app_info (id, name, environment)
    VALUES (1, 'RubyDB example', 'development')
    ON CONFLICT DO NOTHING
  SQL

  puts "Database: #{database_path}"
  puts "Tables: #{engine.list_tables.join(", ")}"
  puts "Rows: #{connection.execute("SELECT * FROM app_info").to_a.inspect}"
ensure
  connection.disconnect
  engine.close
end
