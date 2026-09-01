# frozen_string_literal: true

module RubyDB
  module Catalog
    # Base constraint class
    class Constraint
      attr_reader :name, :type

      def initialize(name, type)
        @name = name
        @type = type
        @created_at = Time.now
      end

      def to_s
        "#{@type} CONSTRAINT #{@name}"
      end

      def serialize
        {
          name: @name,
          type: @type,
          created_at: @created_at.iso8601
        }
      end

      def self.deserialize(data)
        case data[:type]
        when "PRIMARY_KEY"
          PrimaryKeyConstraint.deserialize(data)
        when "FOREIGN_KEY"
          ForeignKeyConstraint.deserialize(data)
        when "UNIQUE"
          UniqueConstraint.deserialize(data)
        when "NOT_NULL"
          NotNullConstraint.deserialize(data)
        when "CHECK"
          CheckConstraint.deserialize(data)
        else
          new(data[:name], data[:type])
        end
      end

      protected

      attr_writer :created_at
    end

    # PRIMARY KEY constraint
    class PrimaryKeyConstraint < Constraint
      attr_reader :columns

      def initialize(name, columns)
        super(name, "PRIMARY_KEY")
        @columns = columns.is_a?(Array) ? columns : [columns]
      end

      def to_s
        "PRIMARY KEY (#{@columns.join(", ")})"
      end

      def serialize
        super.merge(columns: @columns)
      end

      def self.deserialize(data)
        new(data[:name], data[:columns])
      end
    end

    # FOREIGN KEY constraint
    class ForeignKeyConstraint < Constraint
      attr_reader :columns, :reference_table, :reference_columns
      attr_reader :on_delete, :on_update

      def initialize(name, columns, reference_table, reference_columns: [:id], on_delete: nil, on_update: nil)
        super(name, "FOREIGN_KEY")
        @columns = columns.is_a?(Array) ? columns : [columns]
        @reference_table = reference_table
        @reference_columns = reference_columns.is_a?(Array) ? reference_columns : [reference_columns]
        @on_delete = on_delete
        @on_update = on_update
      end

      def to_s
        sql = "FOREIGN KEY (#{@columns.join(", ")}) REFERENCES #{@reference_table}(#{@reference_columns.join(", ")})"
        sql << " ON DELETE #{@on_delete}" if @on_delete
        sql << " ON UPDATE #{@on_update}" if @on_update
        sql
      end

      def serialize
        super.merge(
          columns: @columns,
          reference_table: @reference_table,
          reference_columns: @reference_columns,
          on_delete: @on_delete,
          on_update: @on_update
        )
      end

      def self.deserialize(data)
        new(
          data[:name],
          data[:columns],
          data[:reference_table],
          reference_columns: data[:reference_columns] || [:id],
          on_delete: data[:on_delete],
          on_update: data[:on_update]
        )
      end
    end

    # UNIQUE constraint
    class UniqueConstraint < Constraint
      attr_reader :columns

      def initialize(name, columns)
        super(name, "UNIQUE")
        @columns = columns.is_a?(Array) ? columns : [columns]
      end

      def to_s
        "UNIQUE (#{@columns.join(", ")})"
      end

      def serialize
        super.merge(columns: @columns)
      end

      def self.deserialize(data)
        new(data[:name], data[:columns])
      end
    end

    # NOT NULL constraint
    class NotNullConstraint < Constraint
      attr_reader :column

      def initialize(name, column)
        super(name, "NOT_NULL")
        @column = column
      end

      def to_s
        "#{@column} NOT NULL"
      end

      def serialize
        super.merge(column: @column)
      end

      def self.deserialize(data)
        new(data[:name], data[:column])
      end
    end

    # CHECK constraint
    class CheckConstraint < Constraint
      attr_reader :expression

      def initialize(name, expression)
        super(name, "CHECK")
        @expression = expression
      end

      def to_s
        "CHECK (#{@expression})"
      end

      def serialize
        super.merge(expression: @expression.to_s)
      end

      def self.deserialize(data)
        new(data[:name], data[:expression])
      end
    end
  end
end