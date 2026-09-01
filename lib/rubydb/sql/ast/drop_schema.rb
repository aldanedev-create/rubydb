# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # DROP SCHEMA statement AST node
      class DropSchema < Node
        attr_reader :name, :if_exists, :cascade

        def initialize(name, if_exists: false, cascade: false, location: nil)
          super(location: location)
          @name = name
          @if_exists = if_exists
          @cascade = cascade
        end

        def accept(visitor)
          visitor.visit_drop_schema(self)
        end

        def clone
          DropSchema.new(
            @name,
            if_exists: @if_exists,
            cascade: @cascade,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "DROP SCHEMA"
          parts << "IF EXISTS" if @if_exists
          parts << @name
          parts << "CASCADE" if @cascade
          parts.join(" ")
        end

        def inspect
          str = "DropSchema(name: #{@name}"
          str << ", if_exists: true" if @if_exists
          str << ", cascade: true" if @cascade
          str << ")"
          str
        end
      end
    end
  end
end