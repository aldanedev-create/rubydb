# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # CREATE DATABASE statement AST node
      class CreateDatabase < Node
        attr_reader :name, :if_not_exists

        def initialize(name, if_not_exists: false, location: nil)
          super(location: location)
          @name = name
          @if_not_exists = if_not_exists
        end

        def accept(visitor)
          visitor.visit_create_database(self)
        end

        def clone
          CreateDatabase.new(@name, if_not_exists: @if_not_exists, location: @location)
        end

        def to_sql
          parts = []
          parts << "CREATE DATABASE"
          parts << "IF NOT EXISTS" if @if_not_exists
          parts << @name
          parts.join(" ")
        end

        def inspect
          str = "CreateDatabase(name: #{@name}"
          str << ", if_not_exists: true" if @if_not_exists
          str << ")"
          str
        end
      end
    end
  end
end