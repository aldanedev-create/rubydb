# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      class CreateView < Node
        attr_reader :name, :query, :if_not_exists
        def initialize(name, query, if_not_exists: false, location: nil)
          super(location: location)
          @name = name
          @query = query
          @if_not_exists = if_not_exists
        end
        def accept(visitor) = visitor.visit_create_view(self)
        def clone = self.class.new(@name, @query.clone, if_not_exists: @if_not_exists, location: @location)
        def to_sql = "CREATE VIEW #{@name} AS #{@query.to_sql}"
      end

      class DropView < Node
        attr_reader :name, :if_exists
        def initialize(name, if_exists: false, location: nil)
          super(location: location)
          @name = name
          @if_exists = if_exists
        end
        def accept(visitor) = visitor.visit_drop_view(self)
        def clone = self.class.new(@name, if_exists: @if_exists, location: @location)
        def to_sql = "DROP VIEW #{@name}"
      end
    end
  end
end
