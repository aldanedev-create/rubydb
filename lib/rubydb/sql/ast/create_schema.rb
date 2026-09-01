# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # CREATE SCHEMA statement AST node
      class CreateSchema < Node
        attr_reader :name, :if_not_exists, :authorization

        def initialize(name, if_not_exists: false, authorization: nil, location: nil)
          super(location: location)
          @name = name
          @if_not_exists = if_not_exists
          @authorization = authorization
        end

        def accept(visitor)
          visitor.visit_create_schema(self)
        end

        def clone
          CreateSchema.new(
            @name,
            if_not_exists: @if_not_exists,
            authorization: @authorization,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "CREATE SCHEMA"
          parts << "IF NOT EXISTS" if @if_not_exists
          parts << @name
          if @authorization
            parts << "AUTHORIZATION"
            parts << @authorization
          end
          parts.join(" ")
        end

        def inspect
          str = "CreateSchema(name: #{@name}"
          str << ", if_not_exists: true" if @if_not_exists
          str << ", authorization: #{@authorization}" if @authorization
          str << ")"
          str
        end
      end
    end
  end
end