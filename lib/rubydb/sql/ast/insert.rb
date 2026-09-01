# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # INSERT statement AST node
      class Insert < Node
        attr_reader :table, :columns, :values

        def initialize(table, columns = [], values = [], location: nil)
          super(location: location)
          @table = table
          @columns = columns
          @values = values
        end

        def accept(visitor)
          visitor.visit_insert(self)
        end

        def clone
          Insert.new(
            @table,
            @columns.dup,
            @values.map(&:clone),
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "INSERT INTO #{@table}"

          if @columns.any?
            parts << "(#{@columns.join(", ")})"
          end

          parts << "VALUES"
          parts << "(#{@values.map(&:to_sql).join(", ")})"

          parts.join(" ")
        end

        def inspect
          cols = @columns.any? ? @columns.join(", ") : "ALL"
          vals = @values.map(&:inspect).join(", ")
          "Insert(table: #{@table}, columns: [#{cols}], values: [#{vals}])"
        end

        # Helper methods
        def has_columns?
          @columns.any?
        end

        def value_count
          @values.size
        end

        def column_count
          @columns.size
        end

        # Get column index by name
        def column_index(name)
          @columns.index(name)
        end
      end
    end
  end
end