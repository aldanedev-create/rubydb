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

        # Initialize values
        columns.each do |col|
          @values[col.name] = values[col.name] || col.default
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