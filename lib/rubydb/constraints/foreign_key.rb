# frozen_string_literal: true

module RubyDB
  module Constraints
    # ForeignKeyConstraint - Ensures referential integrity
    class ForeignKeyConstraint < Constraint
      attr_reader :columns, :reference_table, :reference_columns
      attr_reader :on_delete, :on_update, :match_type

      # Referential actions
      ACTION_RESTRICT = :restrict
      ACTION_CASCADE = :cascade
      ACTION_SET_NULL = :set_null
      ACTION_SET_DEFAULT = :set_default
      ACTION_NO_ACTION = :no_action

      def initialize(table_name, columns, reference_table, reference_columns = nil, options = {})
        super(
          options[:name] || "fk_#{table_name}_#{reference_table}",
          TYPE_FOREIGN_KEY,
          table_name,
          options
        )
        @columns = columns.is_a?(Array) ? columns : [columns]
        @reference_table = reference_table
        @reference_columns = reference_columns.is_a?(Array) ? reference_columns : [reference_columns || :id]
        @on_delete = options[:on_delete] || ACTION_NO_ACTION
        @on_update = options[:on_update] || ACTION_NO_ACTION
        @match_type = options[:match] || :simple
        @validated = false
        @reference_cache = {}
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

        # Check if referenced row exists
        key = @columns.map { |col| row[col] }.join("||")
        return true if @reference_cache.key?(key)

        # Check reference table
        ref_exists = check_reference_exists(row)
        if ref_exists
          @reference_cache[key] = true
          true
        else
          @validation_errors << "Referenced row does not exist: #{key}"
          false
        end
      end

      def validate_batch(rows)
        @reference_cache.clear
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

      def check_reference_exists(row)
        # Build reference lookup query
        conditions = {}
        @columns.each_with_index do |col, idx|
          ref_col = @reference_columns[idx] || @reference_columns[0]
          conditions[ref_col.to_s] = row[col]
        end

        # Check if referenced row exists in the reference table
        # This would use the engine to query the reference table
        # For now, return true as a placeholder - production would actually query
        true
      end

      def check_referential_integrity(table_name, row_id)
        # Check if any rows reference this row
        # In production, this would query the table for references
        # Returns true if no references exist, false if references exist
        true
      end

      def to_sql
        cols = @columns.join(", ")
        ref_cols = @reference_columns.join(", ")
        sql = "FOREIGN KEY (#{cols}) REFERENCES #{@reference_table}(#{ref_cols})"
        sql << " ON DELETE #{@on_delete.to_s.upcase}" if @on_delete != ACTION_NO_ACTION
        sql << " ON UPDATE #{@on_update.to_s.upcase}" if @on_update != ACTION_NO_ACTION
        sql << " MATCH #{@match_type.to_s.upcase}"
        sql
      end

      def to_hash
        super.merge({
          columns: @columns,
          reference_table: @reference_table,
          reference_columns: @reference_columns,
          on_delete: @on_delete,
          on_update: @on_update,
          match_type: @match_type
        })
      end

      def inspect
        "#<ForeignKeyConstraint name=#{@name} columns=#{@columns.join(', ')} references=#{@reference_table}>"
      end
    end
  end
end