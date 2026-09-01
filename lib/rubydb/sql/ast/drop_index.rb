# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # DROP INDEX statement AST node
      class DropIndex < Node
        attr_reader :name, :if_exists

        def initialize(name, if_exists: false, location: nil)
          super(location: location)
          @name = name
          @if_exists = if_exists
        end

        def accept(visitor)
          visitor.visit_drop_index(self)
        end

        def clone
          DropIndex.new(@name, if_exists: @if_exists, location: @location)
        end

        def to_sql
          parts = []
          parts << "DROP INDEX"
          parts << "IF EXISTS" if @if_exists
          parts << @name
          parts.join(" ")
        end

        def inspect
          str = "DropIndex(name: #{@name}"
          str << ", if_exists: true" if @if_exists
          str << ")"
          str
        end
      end
    end
  end
end