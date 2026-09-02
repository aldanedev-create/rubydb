# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "VACUUM SQL execution" do
  it "invokes the engine cleanup path and returns its report" do
    Dir.mktmpdir do |dir|
      engine = RubyDB::Storage::Engine.new(File.join(dir, "db.rdb"), auto_vacuum: false)
      statement = RubyDB::SQL::Parser.new(RubyDB::SQL::Lexer.new("VACUUM").tokenize).parse.first
      result = RubyDB::Execution::Executor.new(engine).execute(RubyDB::Execution::Planner.new(engine).plan(statement))
      expect(result[:message]).to eq("VACUUM")
      expect(result[:vacuum]).to include(:removed, :total_rows, :total_vacuumed)
    ensure
      engine&.close if engine&.open?
    end
  end
end
