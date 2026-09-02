# frozen_string_literal: true

module RubyDB
  module Storage
    # Row - Represents a database row with typed values
    class Row
      attr_reader :row_id, :columns, :values
      attr_accessor :record

      def initialize(row_id, columns, values = {})
        @row_id = row_id
        @columns = columns
        @values = {}
        @record = nil
        @dirty = false

        normalized_values = if values.is_a?(Array)
          columns.each_with_index.each_with_object({}) do |(col, index), result|
            result[col.name] = values[index]
          end
        else
          values
        end

        # Initialize values
        columns.each do |col|
          value = if normalized_values.key?(col.name)
                    normalized_values[col.name]
                  elsif normalized_values.key?(col.name.to_sym)
                    normalized_values[col.name.to_sym]
                  else
                    col.default
                  end
          @values[col.name] = value
        end
      end

      def [](column_name)
        @values[column_name]
      end

      def []=(column_name, value)
        @values[column_name] = value
        @dirty = true
      end

      def column_value(column_index)
        column_name = @columns[column_index]&.name
        @values[column_name]
      end

      def to_hash
        @values.dup
      end

      def to_ary
        @columns.map { |col| @values[col.name] }
      end

      def to_sql
        values = @columns.map { |col| @values[col.name] }
        "ROW(#{values.map { |v| v.nil? ? 'NULL' : v.inspect }.join(', ')})"
      end

      def dirty?
        @dirty
      end

      def mark_clean
        @dirty = false
      end

      def clone
        Row.new(@row_id, @columns, @values.dup)
      end
    end
  end
end
