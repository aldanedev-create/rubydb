# frozen_string_literal: true

# Run a join, grouped aggregate, filter, and deterministic order.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "tmpdir"
require "rubydb"

Dir.mktmpdir("rubydb-queries") do |directory|
  engine = RubyDB::Storage::Engine.new(File.join(directory, "queries.rdb"), auto_cleanup: false)
  connection = RubyDB::Rails::Connection.new(engine: engine)
  connection.connect
  begin
    connection.execute("CREATE TABLE authors (id INTEGER PRIMARY KEY, name VARCHAR(100) NOT NULL)")
    connection.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER NOT NULL, title VARCHAR(200) NOT NULL)")
    connection.execute("INSERT INTO authors (id, name) VALUES (1, 'Ada'), (2, 'Grace')")
    connection.execute("INSERT INTO books (id, author_id, title) VALUES (1, 1, 'Storage'), (2, 1, 'Recovery'), (3, 2, 'Compilers')")

    result = connection.execute(<<~SQL).to_a
      SELECT authors.name, COUNT(books.id) AS book_count
      FROM authors
      LEFT JOIN books ON books.author_id = authors.id
      GROUP BY authors.name
      ORDER BY authors.name
    SQL

    counts = result.sort_by { |row| row[:name] || row["name"] }.map { |row| row[:book_count] || row["book_count"] }
    raise "join/aggregate query returned the wrong result" unless counts == [2, 1]
    puts "Join and aggregate result: #{result.inspect}"
  ensure
    connection.disconnect
    engine.close
  end
end
