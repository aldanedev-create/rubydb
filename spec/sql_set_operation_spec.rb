# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL set operations" do
  it "executes UNION, UNION ALL, INTERSECT, and EXCEPT" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "sets.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE a (id INTEGER PRIMARY KEY)")
      connection.execute("CREATE TABLE b (id INTEGER PRIMARY KEY)")
      [1, 2].each { |id| connection.execute("INSERT INTO a (id) VALUES (#{id})") }
      [2, 3].each { |id| connection.execute("INSERT INTO b (id) VALUES (#{id})") }
      expect(connection.execute("SELECT id FROM a UNION SELECT id FROM b").to_a.map { |r| r["id"] }.sort).to eq([1, 2, 3])
      expect(connection.execute("SELECT id FROM a UNION ALL SELECT id FROM b").to_a.size).to eq(4)
      expect(connection.execute("SELECT id FROM a INTERSECT SELECT id FROM b").to_a.map { |r| r["id"] }).to eq([2])
      expect(connection.execute("SELECT id FROM a EXCEPT SELECT id FROM b").to_a.map { |r| r["id"] }).to eq([1])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "rejects operands with different projection widths" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "set-width.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine); connection.connect
      connection.execute("CREATE TABLE a (id INTEGER PRIMARY KEY)")
      expect { connection.execute("SELECT id FROM a UNION SELECT id, id FROM a") }
        .to raise_error(RubyDB::ExecutionError, /same number of columns/)
    ensure
      connection&.disconnect; engine&.close if engine&.open?
    end
  end
end
