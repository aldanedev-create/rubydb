# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
RSpec.describe "SQL IN subqueries" do
  it "filters against a non-correlated SELECT" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "subquery.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine); connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY)")
      connection.execute("CREATE TABLE allowed (id INTEGER PRIMARY KEY)")
      [1, 2, 3].each { |id| connection.execute("INSERT INTO users (id) VALUES (#{id})") }
      [2, 3].each { |id| connection.execute("INSERT INTO allowed (id) VALUES (#{id})") }
      expect(connection.execute("SELECT id FROM users WHERE id IN (SELECT id FROM allowed) ORDER BY id").to_a.map { |row| row["id"] }).to eq([2, 3])
    ensure
      connection&.disconnect; engine&.close if engine&.open?
    end
  end
end
