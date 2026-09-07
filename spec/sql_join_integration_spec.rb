# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL joins" do
  it "executes qualified INNER and LEFT JOIN projections through the normal SQL pipeline" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "joins.rdb"), auto_cleanup: false, auto_vacuum: false)
      connection = RubyDB::Rails::Connection.new(engine: engine)
      connection.connect

      connection.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email VARCHAR(255) NOT NULL)")
      connection.execute("CREATE TABLE projects (id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL, name VARCHAR(255) NOT NULL)")
      connection.execute("INSERT INTO accounts (id, email) VALUES (1, 'ada@example.test')")
      connection.execute("INSERT INTO accounts (id, email) VALUES (2, 'grace@example.test')")
      connection.execute("INSERT INTO projects (id, account_id, name) VALUES (10, 1, 'RubyDB')")

      inner = connection.execute(<<~SQL)
        SELECT projects.name AS project_name, accounts.email AS account_email
        FROM projects INNER JOIN accounts ON accounts.id = projects.account_id
      SQL
      left = connection.execute(<<~SQL)
        SELECT accounts.*, projects.name AS project_name
        FROM accounts LEFT OUTER JOIN projects ON accounts.id = projects.account_id
        ORDER BY accounts.id
      SQL

      expect(inner.to_a).to eq([{ "project_name" => "RubyDB", "account_email" => "ada@example.test" }])
      expect(left.to_a).to eq([
        { "id" => 1, "email" => "ada@example.test", "project_name" => "RubyDB" },
        { "id" => 2, "email" => "grace@example.test", "project_name" => nil }
      ])
    ensure
      connection&.disconnect
      engine&.close if engine&.open?
    end
  end
end
