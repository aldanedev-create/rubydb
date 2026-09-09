# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe RubyDB::Execution::Planner do
  it "orders dependent inner joins by cardinality without moving outer joins" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "planner.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      %w[a b c].each { |table| engine.create_table(table, columns) }

      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new(<<~SQL).tokenize
          SELECT a.id FROM a
          INNER JOIN c ON b.id = c.id
          INNER JOIN b ON a.id = b.id
        SQL
      ).parse.first
      plan = described_class.new(engine).plan(statement)

      expect(plan.joins.map { |join| join[:table].name.to_s }).to eq(["b", "c"])
    ensure
      engine&.close if engine&.open?
    end
  end

  it "preserves source order when an outer join is present" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "outer-planner.rdb"), auto_cleanup: false, auto_vacuum: false)
      columns = [RubyDB::Catalog::Column.new(:id, :integer, primary_key: true, null: false)]
      %w[a b c].each { |table| engine.create_table(table, columns) }
      statement = RubyDB::SQL::Parser.new(
        RubyDB::SQL::Lexer.new("SELECT a.id FROM a LEFT JOIN c ON a.id = c.id INNER JOIN b ON a.id = b.id").tokenize
      ).parse.first

      plan = described_class.new(engine).plan(statement)
      expect(plan.joins.map { |join| join[:table].name.to_s }).to eq(["c", "b"])
    ensure
      engine&.close if engine&.open?
    end
  end
end
