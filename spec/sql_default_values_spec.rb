# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL DEFAULT VALUES" do
  it "inserts a row using every declared default" do
    Dir.mktmpdir("rubydb-default-values") do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "defaults.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect
      connection.execute(<<~SQL)
        CREATE TABLE settings (
          id INTEGER PRIMARY KEY,
          label VARCHAR(64) NOT NULL DEFAULT '',
          enabled BOOLEAN NOT NULL DEFAULT TRUE
        )
      SQL

      result = connection.execute("INSERT INTO settings DEFAULT VALUES")

      expect(result.affected_rows).to eq(1)
      expect(connection.execute("SELECT label, enabled FROM settings").to_a).to eq([
        { "label" => "", "enabled" => true }
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
