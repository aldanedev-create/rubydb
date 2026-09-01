# frozen_string_literal: true

require "set"

module RubyDB
  module Constraints
    # UniqueConstraint - Ensures unique values in columns
    class UniqueConstraint < Constraint
      attr_reader :columns

      def initialize(table_name, columns, options = {})
        super(
          options[:name] || "uniq_#{table_name}_#{columns.join('_')}",
          TYPE_UNIQUE,
          table_name,
          options
        )
        @columns = columns.is_a?(Array) ? columns : [columns]
        @nulls_distinct = options[:nulls_distinct] != false
        @validated = false
        @existing_keys = Set.new
      end

      def validate(row)
        return true unless enabled?

        # Build key from column values
        key = build_key(row)

        # Check if key already exists (duplicate)
        if @existing_keys.include?(key)
          @validation_errors << "Duplicate value for unique constraint: #{key}"
          return false
        end

        @existing_keys.add(key)
        true
      end

      def validate_batch(rows)
        @existing_keys = Set.new
        results = { valid: [], invalid: [] }

        rows.each do |row|
          key = build_key(row)

          # Skip if all values are NULL and nulls_distinct is true
          if @nulls_distinct && all_null?(row)
            results[:valid] << row
            next
          end

          if @existing_keys.include?(key)
            @validation_errors << "Duplicate value for unique constraint: #{key}"
            results[:invalid] << row
          else
            @existing_keys.add(key)
            results[:valid] << row
          end
        end

        results
      end

      def build_key(row)
        @columns.map { |col| row[col] }.join("||")
      end

      def all_null?(row)
        @columns.all? { |col| row[col].nil? }
      end

      def check_duplicates(rows)
        seen = Set.new
        duplicates = []

        rows.each do |row|
          key = build_key(row)
          if seen.include?(key)
            duplicates << row
          else
            seen.add(key)
          end
        end

        duplicates
      end

      def to_sql
        cols = @columns.join(", ")
        sql = "UNIQUE (#{cols})"
        sql << " NULLS NOT DISTINCT" unless @nulls_distinct
        sql
      end

      def to_hash
        super.merge({
          columns: @columns,
          nulls_distinct: @nulls_distinct
        })
      end

      def inspect
        "#<UniqueConstraint name=#{@name} columns=#{@columns.join(', ')}>"
      end
    end
  end
end