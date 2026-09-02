# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "SQL trigger DDL" do
  it "creates and drops a trigger definition" do
    Dir.mktmpdir do |dir|
      catalog = RubyDB::Catalog::Catalog.new
      catalog.create_database("app")
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), catalog: catalog, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new("id", :integer)]
      engine.create_table("users", columns)
      planner = RubyDB::Execution::Planner.new(engine)
      executor = RubyDB::Execution::Executor.new(engine)

      create = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("CREATE TRIGGER audit AFTER INSERT ON users EXECUTE FUNCTION audit_user()").tokenize).parse.first
      executor.execute(planner.plan(create))
      expect(catalog.find_trigger("audit").function_name).to eq("audit_user")

      drop = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("DROP TRIGGER IF EXISTS audit").tokenize).parse.first
      executor.execute(planner.plan(drop))
      expect(catalog.find_trigger("audit")).to be_nil
    ensure
      engine&.close if engine&.open?
    end
  end
end
