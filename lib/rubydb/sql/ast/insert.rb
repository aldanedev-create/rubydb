# frozen_string_literal: true

module RubyDB
  module SQL
    module AST
      # INSERT statement AST node
      class Insert < Node
        attr_reader :table, :columns, :values, :rows, :on_conflict
        attr_reader :default_values

        def initialize(table, columns = [], values = [], rows: nil, on_conflict: nil, default_values: false, location: nil)
          super(location: location)
          @table = table
          @columns = columns
          @rows = rows || [values]
          @values = @rows.first || []
          @on_conflict = on_conflict
          @default_values = default_values
        end

        def accept(visitor)
          visitor.visit_insert(self)
        end

        def clone
          Insert.new(
            @table,
            @columns.dup,
            @values.map(&:clone), rows: @rows.map { |row| row.map(&:clone) }, on_conflict: @on_conflict,
            default_values: @default_values,
            location: @location
          )
        end

        def to_sql
          parts = []
          parts << "INSERT INTO #{@table}"

          if @columns.any?
            parts << "(#{@columns.join(", ")})"
          end

          if @default_values
            parts << "DEFAULT VALUES"
          else
            parts << "VALUES"
            parts << @rows.map { |row| "(#{row.map(&:to_sql).join(", ")})" }.join(", ")
          end
          parts << "ON CONFLICT DO NOTHING" if @on_conflict == :nothing
          if @on_conflict.is_a?(Hash) && @on_conflict[:action] == :update
            target = @on_conflict[:target].any? ? " (#{@on_conflict[:target].join(', ')})" : ""
            assignments = @on_conflict[:assignments].map(&:to_sql).join(", ")
            parts << "ON CONFLICT#{target} DO UPDATE SET #{assignments}"
          end

          parts.join(" ")
        end

        def inspect
          cols = @columns.any? ? @columns.join(", ") : "ALL"
          vals = @rows.map { |row| "(#{row.map(&:inspect).join(", ")})" }.join(", ")
          "Insert(table: #{@table}, columns: [#{cols}], values: [#{vals}])"
        end

        # Helper methods
        def has_columns?
          @columns.any?
        end

        def default_values?
          @default_values
        end

        def value_count
          @values.size
        end

        def row_count
          @rows.size
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
