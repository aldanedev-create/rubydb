# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # COMMIT statement AST node
      class Commit < Node
        attr_reader :chain

        def initialize(chain: false, location: nil)
          super(location: location)
          @chain = chain
        end

        def accept(visitor)
          visitor.visit_commit(self)
        end

        def clone
          Commit.new(chain: @chain, location: @location)
        end

        def to_sql
          parts = ["COMMIT"]
          parts << "AND CHAIN" if @chain
          parts.join(" ")
        end

        def inspect
          str = "Commit"
          str << " (chain: true)" if @chain
          str
        end
      end
    end
  end
end