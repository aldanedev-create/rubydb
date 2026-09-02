# frozen_string_literal: true

# A minimal Rails application using RubyDB through the real ActiveRecord adapter.
# Run from this directory with:
#   ruby smoke_test.rb

require_relative "config/application"
$stdout.sync = true
puts "Booting Rails"
RubydbRailsSmoke::Application.initialize!

database_path = File.expand_path("rubydb_rails.rdb", __dir__)
puts "Opening RubyDB database at #{database_path}"
engine = RubyDB::Storage::Engine.new(database_path, auto_cleanup: false, auto_vacuum: false)
begin
  puts "Establishing ActiveRecord connection"
  ActiveRecord::Base.establish_connection(adapter: "rubydb", engine: engine)

  connection = ActiveRecord::Base.connection
  puts "Creating accounts table"
  unless connection.table_exists?(:accounts)
    connection.execute(<<~SQL)
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY,
        email VARCHAR(255) NOT NULL,
        active BOOLEAN NOT NULL
      )
    SQL
  end

  require_relative "app/models/account"
  account = Account.find_by(email: "grace@example.test")
  account ||= Account.create!(id: 1, email: "grace@example.test", active: true)
  loaded = Account.find(account.id)
  raise "ActiveRecord returned the wrong row" unless loaded.email == "grace@example.test" && loaded.active == true

  puts "RubyDB Rails app passed: #{loaded.attributes.inspect}"
ensure
  ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  engine&.close
end
