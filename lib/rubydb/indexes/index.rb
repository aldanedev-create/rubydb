# frozen_string_literal: true

module RubyDB
  module Indexes
    # Base class for all index types
    class Index
      attr_reader :name, :table_name, :columns, :unique, :type, :options
      attr_accessor :size, :entries_count

      def initialize(name, table_name, columns, options = {})
        @name = name
        @table_name = table_name
        @columns = columns.is_a?(Array) ? columns : [columns]
        @unique = options[:unique] || false
        @type = options[:type] || :btree
        @options = options
        @size = 0
        @entries_count = 0
        @created_at = Time.now
        @modified_at = Time.now
        @is_built = false
      end

      def insert(key, row_id)
        raise NotImplementedError, "#{self.class} must implement #insert"
      end

      def delete(key, row_id)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end

      def search(key)
        raise NotImplementedError, "#{self.class} must implement #search"
      end

      def range_search(start_key, end_key)
        raise NotImplementedError, "#{self.class} must implement #range_search"
      end

      def build(rows)
        raise NotImplementedError, "#{self.class} must implement #build"
      end

      def clear
        raise NotImplementedError, "#{self.class} must implement #clear"
      end

      def analyze
        {
          name: @name,
          table: @table_name,
          columns: @columns,
          type: @type,
          unique: @unique,
          entries: @entries_count,
          size: @size,
          created_at: @created_at,
          modified_at: @modified_at
        }
      end

      def to_s
        "#{@type.to_s.upcase} INDEX #{@name} ON #{@table_name}(#{@columns.join(', ')})"
      end

      def inspect
        to_s
      end
    end
  end
end