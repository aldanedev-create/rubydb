# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # A materialized WITH query. Recursive CTEs are evaluated iteratively by
      # the executor with a bounded working set.
      class With < Node
        attr_reader :ctes, :query, :recursive

        def initialize(ctes, query, recursive: false, location: nil)
          super(location: location)
          @ctes = ctes
          @query = query
          @recursive = recursive
        end

        def accept(visitor) = visitor.visit_with(self)

        def clone
          With.new(@ctes.map { |name, query| [name, query.clone] }, @query.clone, recursive: @recursive, location: @location)
        end

        def to_sql
          definitions = @ctes.map { |name, query| "#{name} AS (#{query.to_sql})" }.join(", ")
          prefix = @recursive ? "WITH RECURSIVE" : "WITH"
          "#{prefix} #{definitions} #{@query.to_sql}"
        end
      end
    end
  end
end
