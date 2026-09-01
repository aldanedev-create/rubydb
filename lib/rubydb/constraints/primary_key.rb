# frozen_string_literal: true

module RubyDB
  module Constraints
    # PrimaryKeyConstraint - Ensures unique identification of rows
    class PrimaryKeyConstraint < Constraint
      attr_reader :columns

      def initialize(table_name, columns, options = {})
        super(
          options[:name] || "pk_#{table_name}",
          TYPE_PRIMARY_KEY,
          table_name,
          options
        )
        @columns = columns.is_a?(Array) ? columns : [columns]
        @auto_increment = options[:auto_increment] || false
        @sequence_name = options[:sequence_name] || "seq_#{table_name}_#{@columns.first}"
        @validated = false
      end

      def validate(row)
        return true unless enabled?

        # Check all columns are present
        @columns.each do |col|
          if row[col].nil?
            @validation_errors << "Column '#{col}' cannot be NULL"
            return false
          end
        end

        # Check uniqueness
        key = @columns.map { |col| row[col] }.join("||")
        if @existing_keys && @existing_keys.include?(key)
          @validation_errors << "Duplicate primary key: #{key}"
          return false
        end

        true
      end

      def validate_batch(rows)
        @existing_keys = Set.new
        results = { valid: [], invalid: [] }

        rows.each do |row|
          # Check all columns are present
          all_present = true
          @columns.each do |col|
            if row[col].nil?
              all_present = false
              @validation_errors << "Column '#{col}' cannot be NULL"
            end
          end

          if all_present
            key = @columns.map { |col| row[col] }.join("||")
            if @existing_keys.include?(key)
              @validation_errors << "Duplicate primary key: #{key}"
              results[:invalid] << row
            else
              @existing_keys.add(key)
              results[:valid] << row
            end
          else
            results[:invalid] << row
          end
        end

        results
      end

      def generate_next_id(current_max = 0)
        return nil unless @auto_increment
        current_max + 1
      end

      def to_sql
        cols = @columns.join(", ")
        sql = "PRIMARY KEY (#{cols})"
        sql << " AUTO_INCREMENT" if @auto_increment
        sql
      end

      def to_hash
        super.merge({
          columns: @columns,
          auto_increment: @auto_increment,
          sequence_name: @sequence_name
        })
      end

      def inspect
        "#<PrimaryKeyConstraint name=#{@name} columns=#{@columns.join(', ')}>"
      end
    end
  end
end