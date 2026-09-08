# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
RSpec.describe "SQL scalar subqueries" do
  it "projects a single-value subquery and rejects multiple rows" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "scalar.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine); connection.connect
      connection.execute("CREATE TABLE items (id INTEGER PRIMARY KEY)")
      [1, 2].each { |id| connection.execute("INSERT INTO items (id) VALUES (#{id})") }
      expect(connection.execute("SELECT (SELECT COUNT(*) FROM items) AS total FROM items LIMIT 1").to_a).to eq([{ "total" => 2 }])
      expect { connection.execute("SELECT (SELECT id FROM items) AS invalid FROM items LIMIT 1") }
        .to raise_error(RubyDB::ExecutionError, /more than one row/)
    ensure
      connection&.disconnect; engine&.close if engine&.open?
    end
  end
end
