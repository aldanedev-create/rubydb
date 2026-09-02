# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyDB::Recovery::Redo do
  EngineDouble = Struct.new(:rows, :tables) do
    def select_row(table, row_id, _columns)
      rows[[table, row_id]]
    end

    def table_exists?(table)
      tables.include?(table)
    end
  end

  def redo_checker(engine)
    described_class.new(engine, nil)
  end

  def record(type, data)
    RubyDB::WAL::Record.new(type, data)
  end

  it "detects an already-applied insert, update, and delete" do
    engine = EngineDouble.new({ ["users", 1] => { id: 1, name: "Ada" } }, ["users"])
    checker = redo_checker(engine)

    expect(checker.send(:already_applied?, record(:insert, table: "users", row_id: 1))).to be(true)
    expect(checker.send(:already_applied?, record(:update, table: "users", row_id: 1, values: { name: "Ada" }))).to be(true)
    expect(checker.send(:already_applied?, record(:delete, table: "users", row_id: 2))).to be(true)
  end

  it "detects already-applied table creation and drop" do
    engine = EngineDouble.new({}, ["users"])
    checker = redo_checker(engine)

    expect(checker.send(:already_applied?, record(:create_table, table_name: "users"))).to be(true)
    expect(checker.send(:already_applied?, record(:drop_table, table_name: "orders"))).to be(true)
  end
end
