# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # A materialized, non-recursive WITH query. Each CTE is evaluated once
      # and is visible to later CTEs and the final query only.
      class With < Node
        attr_reader :ctes, :query

        def initialize(ctes, query, location: nil)
          super(location: location)
          @ctes = ctes
          @query = query
        end

        def accept(visitor) = visitor.visit_with(self)

        def clone
          With.new(@ctes.map { |name, query| [name, query.clone] }, @query.clone, location: @location)
        end

        def to_sql
          definitions = @ctes.map { |name, query| "#{name} AS (#{query.to_sql})" }.join(", ")
          "WITH #{definitions} #{@query.to_sql}"
        end
      end
    end
  end
end
