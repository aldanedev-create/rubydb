# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # SAVEPOINT statement AST node
      class Savepoint < Node
        attr_reader :name

        def initialize(name, location: nil)
          super(location: location)
          @name = name
        end

        def accept(visitor)
          visitor.visit_savepoint(self)
        end

        def clone
          Savepoint.new(@name, location: @location)
        end

        def to_sql
          "SAVEPOINT #{@name}"
        end

        def inspect
          "Savepoint(name: #{@name})"
        end
      end

      # RELEASE SAVEPOINT statement AST node
      class ReleaseSavepoint < Node
        attr_reader :name

        def initialize(name, location: nil)
          super(location: location)
          @name = name
        end

        def accept(visitor)
          visitor.visit_release_savepoint(self)
        end

        def clone
          ReleaseSavepoint.new(@name, location: @location)
        end

        def to_sql
          "RELEASE SAVEPOINT #{@name}"
        end

        def inspect
          "ReleaseSavepoint(name: #{@name})"
        end
      end
    end
  end
end