# frozen_string_literal: true

# Demonstrate a committed transaction and a rolled-back transaction.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-transactions") do |directory|
  engine = RubyDB::Storage::Engine.new(File.join(directory, "transactions.rdb"), auto_cleanup: false)
  connection = RubyDB::Rails::Connection.new(engine: engine)
  connection.connect
  begin
    connection.execute("CREATE TABLE ledger (id INTEGER PRIMARY KEY, description VARCHAR(100) NOT NULL, amount INTEGER NOT NULL)")

    transaction_id = engine.begin_transaction(:read_committed)
    connection.execute("INSERT INTO ledger (id, description, amount) VALUES (1, 'deposit', 100)")
    connection.execute("INSERT INTO ledger (id, description, amount) VALUES (2, 'fee', -5)")
    raise "commit failed" unless engine.commit_transaction
    puts "Committed transaction #{transaction_id}"

    engine.begin_transaction
    connection.execute("INSERT INTO ledger (id, description, amount) VALUES (3, 'rolled back', 999)")
    raise "rollback failed" unless engine.rollback_transaction

    rows = connection.execute("SELECT * FROM ledger ORDER BY id").to_a
    raise "rollback leaked a row" unless rows.length == 2
    puts "Rows after rollback: #{rows.inspect}"
  ensure
    connection.disconnect
    engine.close
  end
end
