# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # ROLLBACK statement AST node
      class Rollback < Node
        attr_reader :chain

        def initialize(chain: false, location: nil)
          super(location: location)
          @chain = chain
        end

        def accept(visitor)
          visitor.visit_rollback(self)
        end

        def clone
          Rollback.new(chain: @chain, location: @location)
        end

        def to_sql
          parts = ["ROLLBACK"]
          parts << "AND CHAIN" if @chain
          parts.join(" ")
        end

        def inspect
          str = "Rollback"
          str << " (chain: true)" if @chain
          str
        end
      end

      # ROLLBACK TO SAVEPOINT statement AST node
      class RollbackToSavepoint < Node
        attr_reader :savepoint_name

        def initialize(savepoint_name, location: nil)
          super(location: location)
          @savepoint_name = savepoint_name
        end

        def accept(visitor)
          visitor.visit_rollback_to_savepoint(self)
        end

        def clone
          RollbackToSavepoint.new(@savepoint_name, location: @location)
        end

        def to_sql
          "ROLLBACK TO SAVEPOINT #{@savepoint_name}"
        end

        def inspect
          "RollbackToSavepoint(savepoint: #{@savepoint_name})"
        end
      end
    end
  end
end