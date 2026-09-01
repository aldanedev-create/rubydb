# frozen_string_literal: true

module RubyDB
  module Catalog
    # Table - contains columns, indexes, constraints
    class Table
      attr_reader :name, :columns, :indexes, :constraints, :database
      attr_accessor :row_count, :storage_size

      def initialize(name, database = nil)
        @name = name
        @database = database
        @columns = []
        @columns_by_name = {}
        @indexes = {}
        @constraints = []
        @row_count = 0
        @storage_size = 0
        @created_at = Time.now
        @modified_at = Time.now
        @options = {}
      end

      # --- Column Methods ---

      def add_column(column)
        if @columns_by_name.key?(column.name)
          raise DatabaseError, "Column '#{column.name}' already exists in table '#{@name}'"
        end

        @columns << column
        @columns_by_name[column.name] = column
        @modified_at = Time.now
        column
      end

      def drop_column(name)
        column = @columns_by_name.delete(name)
        @columns.delete(column) if column
        @modified_at = Time.now
        column
      end

      def find_column(name)
        @columns_by_name[name]
      end

      def column_exists?(name)
        @columns_by_name.key?(name)
      end

      def columns
        @columns.dup
      end

      # --- Index Methods ---

      def add_index(index)
        if @indexes.key?(index.name)
          raise DatabaseError, "Index '#{index.name}' already exists in table '#{@name}'"
        end

        @indexes[index.name] = index
        @modified_at = Time.now
        index
      end

      def drop_index(name)
        index = @indexes.delete(name)
        @modified_at = Time.now
        index
      end

      def find_index(name)
        @indexes[name]
      end

      def indexes
        @indexes.values
      end

      # --- Constraint Methods ---

      def add_constraint(constraint)
        @constraints << constraint
        @modified_at = Time.now
        constraint
      end

      def drop_constraint(name)
        constraint = @constraints.find { |c| c.name == name }
        @constraints.delete(constraint) if constraint
        @modified_at = Time.now
        constraint
      end

      def constraints
        @constraints.dup
      end

      def primary_key
        @constraints.find { |c| c.is_a?(PrimaryKeyConstraint) }
      end

      def foreign_keys
        @constraints.select { |c| c.is_a?(ForeignKeyConstraint) }
      end

      def unique_constraints
        @constraints.select { |c| c.is_a?(UniqueConstraint) }
      end

      # --- Helpers ---

      def primary_key_column
        pk = primary_key
        return nil unless pk
        find_column(pk.columns.first)
      end

      def column_names
        @columns.map(&:name)
      end

      def column_types
        @columns.map { |c| [c.name, c.type] }.to_h
      end

      def to_s
        "#{@name}(#{@columns.map(&:name).join(", ")})"
      end

      # --- Serialization ---

      def serialize
        {
          name: @name,
          created_at: @created_at.iso8601,
          modified_at: @modified_at.iso8601,
          columns: @columns.map(&:serialize),
          indexes: @indexes.transform_values(&:serialize),
          constraints: @constraints.map(&:serialize),
          row_count: @row_count,
          storage_size: @storage_size,
          options: @options
        }
      end

      def self.deserialize(data)
        table = new(data[:name])

        data[:columns]&.each do |col_data|
          table.add_column(Column.deserialize(col_data))
        end

        data[:indexes]&.each do |name, idx_data|
          table.indexes[name] = Index.deserialize(idx_data)
        end

        data[:constraints]&.each do |con_data|
          table.constraints << Constraint.deserialize(con_data)
        end

        table.row_count = data[:row_count] if data[:row_count]
        table.storage_size = data[:storage_size] if data[:storage_size]
        table.options = data[:options] if data[:options]
        table.created_at = Time.parse(data[:created_at]) if data[:created_at]
        table.modified_at = Time.parse(data[:modified_at]) if data[:modified_at]

        table
      end

      protected

      attr_writer :created_at, :modified_at, :options
    end
  end
end