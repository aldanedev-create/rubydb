# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL NULL and boolean semantics" do
  it "preserves false values and treats NULL comparisons as unknown" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "nulls.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE flags (id INTEGER PRIMARY KEY, active BOOLEAN, note VARCHAR(32))")
      connection.execute("INSERT INTO flags (id, active, note) VALUES (1, TRUE, 'yes')")
      connection.execute("INSERT INTO flags (id, active, note) VALUES (2, FALSE, 'no')")
      connection.execute("INSERT INTO flags (id, active, note) VALUES (3, NULL, NULL)")

      expect(connection.execute("SELECT id, active FROM flags WHERE active = FALSE ORDER BY id").to_a)
        .to eq([{"id" => 2, "active" => false}])
      expect(connection.execute("SELECT id FROM flags WHERE note = NULL").to_a).to eq([])
      expect(connection.execute("SELECT id FROM flags WHERE active IS NULL").to_a).to eq([{"id" => 3}])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end

  it "keeps outer-join NULL extension distinct from stored false values" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "outer-null.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute("CREATE TABLE parents (id INTEGER PRIMARY KEY)")
      connection.execute("CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER, active BOOLEAN)")
      connection.execute("INSERT INTO parents (id) VALUES (1)")
      connection.execute("INSERT INTO parents (id) VALUES (2)")
      connection.execute("INSERT INTO children (id, parent_id, active) VALUES (10, 1, FALSE)")

      result = connection.execute(<<~SQL).to_a
        SELECT parents.id AS parent_id, children.active
        FROM parents LEFT JOIN children ON parents.id = children.parent_id
        ORDER BY parents.id
      SQL
      expect(result).to eq([
        {"parent_id" => 1, "active" => false},
        {"parent_id" => 2, "active" => nil}
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
