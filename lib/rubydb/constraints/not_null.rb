# frozen_string_literal: true

module RubyDB
  module Constraints
    # NotNullConstraint - Ensures column is not NULL
    class NotNullConstraint < Constraint
      attr_reader :column

      def initialize(table_name, column, options = {})
        super(
          options[:name] || "nn_#{table_name}_#{column}",
          TYPE_NOT_NULL,
          table_name,
          options
        )
        @column = column
        @validated = false
      end

      def validate(row)
        return true unless enabled?

        if row[@column].nil?
          @validation_errors << "Column '#{@column}' cannot be NULL"
          return false
        end

        true
      end

      def validate_batch(rows)
        results = { valid: [], invalid: [] }

        rows.each do |row|
          if validate(row)
            results[:valid] << row
          else
            results[:invalid] << row
          end
        end

        results
      end

      def find_null_rows(rows)
        rows.select { |row| row[@column].nil? }
      end

      def to_sql
        "#{@column} NOT NULL"
      end

      def to_hash
        super.merge({
          column: @column
        })
      end

      def inspect
        "#<NotNullConstraint name=#{@name} column=#{@column}>"
      end
    end
  end
end