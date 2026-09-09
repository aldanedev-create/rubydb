# frozen_string_literal: true

# Shared SQL execution path for fuzzers. Keeping this on the public planner and
# executor path ensures fuzz runs exercise the same engine code as clients.
module RubyDB
  module Fuzz
    module Support
      module_function

      def execute(engine, sql, transaction_id = nil)
        lexer = RubyDB::SQL::Lexer.new(sql)
        parser = RubyDB::SQL::Parser.new(lexer.tokenize)
        parser.parse.map do |statement|
          plan = RubyDB::Execution::Planner.new(engine).plan(statement)
          RubyDB::Execution::Executor.new(engine).execute(plan, transaction_id)
        end
      end
    end
  end
end
