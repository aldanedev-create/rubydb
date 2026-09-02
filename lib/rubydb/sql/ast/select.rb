# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # SELECT statement AST node
      class Select < Node
        attr_reader :columns, :from, :where, :order_by, :limit, :offset, :distinct, :group_by

        def initialize(columns, from, where = nil, order_by = nil, limit = nil, offset = nil, distinct = false, location: nil)
          super(location: location)
          @columns = columns
          @from = from
          @where = where
          @order_by = order_by || []
          @limit = limit
          @offset = offset
          @distinct = distinct
          @group_by = []
        end

        def accept(visitor)
          visitor.visit_select(self)
        end

        def clone
          Select.new(
            @columns.map(&:clone),
            @from.clone,
            @where&.clone,
            @order_by.map(&:clone),
            @limit&.clone,
            @offset&.clone,
            @distinct,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "SELECT"
          parts << "DISTINCT" if @distinct
          parts << @columns.map(&:to_sql).join(", ")
          parts << "FROM #{@from.to_sql}"
          parts << "WHERE #{@where.to_sql}" if @where
          parts << "ORDER BY #{@order_by.map(&:to_sql).join(", ")}" if @order_by.any?
          parts << "LIMIT #{@limit.to_sql}" if @limit
          parts << "OFFSET #{@offset.to_sql}" if @offset
          parts.join(" ")
        end

        def inspect
          cols = @columns.map(&:inspect).join(", ")
          str = "Select(columns: [#{cols}], from: #{@from.inspect}"
          str << ", where: #{@where.inspect}" if @where
          str << ", order_by: #{@order_by.map(&:inspect).join(", ")}" if @order_by.any?
          str << ", limit: #{@limit.inspect}" if @limit
          str << ", offset: #{@offset.inspect}" if @offset
          str << ", distinct: true" if @distinct
          str << ")"
          str
        end

        # Helper methods for semantic analysis
        def has_star?
          @columns.any? do |col|
            col.is_a?(Star) || (col.respond_to?(:expression) && col.expression.is_a?(Star))
          end
        end

        def column_count
          @columns.size
        end

        def table_name
          @from.name
        end
      end
    end
  end
end
