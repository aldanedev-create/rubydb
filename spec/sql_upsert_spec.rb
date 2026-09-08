# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
RSpec.describe "SQL conflict handling" do
  it "ignores only duplicate-key inserts with ON CONFLICT DO NOTHING" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "upsert.rdb"), auto_cleanup: false)
      connection = RubyDB::Rails::Connection.new(engine: engine); connection.connect
      connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email VARCHAR(64) UNIQUE)")
      connection.execute("INSERT INTO users (id, email) VALUES (1, 'a@example.test')")
      result = connection.execute("INSERT INTO users (id, email) VALUES (1, 'b@example.test') ON CONFLICT DO NOTHING")
      expect(result.affected_rows).to eq(0)
      expect(connection.execute("SELECT email FROM users").to_a).to eq([{ "email" => "a@example.test" }])
      expect { connection.execute("INSERT INTO missing (id) VALUES (1) ON CONFLICT DO NOTHING") }.to raise_error(RubyDB::DatabaseError)
    ensure
      connection&.disconnect; engine&.close if engine&.open?
    end
  end
end
