# frozen_string_literal: true

# Create a constrained table and maintain a unique index with SQL.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-create-table") do |directory|
  engine = RubyDB::Storage::Engine.new(File.join(directory, "catalog.rdb"), auto_cleanup: false)
  connection = RubyDB::Rails::Connection.new(engine: engine)
  connection.connect
  begin
    connection.execute(<<~SQL)
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        email VARCHAR(255) NOT NULL,
        active BOOLEAN NOT NULL DEFAULT TRUE
      )
    SQL
    connection.execute("CREATE UNIQUE INDEX users_email_idx ON users (email)")
    connection.execute("INSERT INTO users (id, email, active) VALUES (1, 'ada@example.test', TRUE)")
    connection.execute("INSERT INTO users (id, email, active) VALUES (2, 'grace@example.test', FALSE)")

    users = connection.execute("SELECT id, email, active FROM users ORDER BY id").to_a
    raise "unexpected user count" unless users.length == 2
    puts "Created users table and unique email index"
    puts users.inspect
  ensure
    connection.disconnect
    engine.close
  end
end
