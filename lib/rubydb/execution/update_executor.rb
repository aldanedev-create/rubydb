# frozen_string_literal: true

module RubyDB
  module Execution
    # UpdateExecutor - Executes UPDATE operations
    class UpdateExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          updates: 0,
          rows_updated: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:updates] += 1

          table_name = plan.table_name
          assignments = plan.assignments
          predicate = plan.predicate

          # Get table columns
          table_columns = @engine.table_columns(table_name)
          raise ExecutionError, "Table '#{table_name}' does not exist" if table_columns.empty?

          # Find rows to update
          rows = find_rows(table_name, predicate)

          updated_count = 0
          updated_rows = []

          rows.each do |row|
            # Get row ID
            row_id = row[:_row_id] || row["_row_id"] || row[:id] || row["id"]
            
            # Apply updates
            row_data = row.dup
            assignments.each do |assignment|
              column = assignment.column.to_s
              value = evaluate_expression(assignment.value, row)
              row_data[column] = value
            end

            # Validate constraints
            validate_constraints(table_name, row_data)

            # Update in engine
            @engine.update_row(table_name, row_id, row_data, transaction_id: transaction_id)

            updated_count += 1
            updated_rows << { row_id: row_id, old: row, new: row_data }
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_updated] += updated_count
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: updated_rows,
            row_count: updated_count,
            row_ids: updated_rows.map { |r| r[:row_id] },
            message: "UPDATE #{updated_count}"
          }
        end
      end

      def execute_batch(plan, updates, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:updates] += 1

          table_name = plan.table_name
          table_columns = @engine.table_columns(table_name)

          updated_count = 0
          updated_rows = []

          updates.each do |update|
            row_id = update[:row_id]
            row_data = update[:values]

            # Validate constraints
            validate_constraints(table_name, row_data)

            # Update in engine
            old_row = @engine.select_row(table_name, row_id, table_columns)
            @engine.update_row(table_name, row_id, row_data, transaction_id: transaction_id)

            updated_count += 1
            updated_rows << { row_id: row_id, old: old_row, new: row_data }
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_updated] += updated_count
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: updated_rows,
            row_count: updated_count,
            row_ids: updated_rows.map { |r| r[:row_id] },
            message: "UPDATE #{updated_count}"
          }
        end
      end

      private

      def find_rows(table_name, predicate)
        table_columns = @engine.table_columns(table_name)
        rows = @engine.select_rows(table_name, table_columns)

        if predicate
          rows.select { |row| predicate.evaluate(row) }
        else
          rows
        end
      end

      def evaluate_expression(expr, row)
        case expr
        when Expression
          expr.evaluate(row)
        when Hash
          expr.transform_values { |v| evaluate_expression(v, row) }
        when Array
          expr.map { |v| evaluate_expression(v, row) }
        else
          expr
        end
      end

      def validate_constraints(table_name, row_data)
        table_columns = @engine.table_columns(table_name)
        table_columns.each do |col|
          # Check NOT NULL
          if !col.nullable? && row_data[col.name].nil?
            raise ConstraintError, "Column '#{col.name}' cannot be NULL"
          end

          # Check UNIQUE
          if col.unique?
            conditions = { col.name => row_data[col.name] }
            existing = @engine.select_rows(table_name, table_columns, conditions)
            if existing.any? && existing.first[:_row_id] != row_data[:_row_id]
              raise ConstraintError, "Duplicate value for unique column '#{col.name}'"
            end
          end
        end
      end

      def stats
        @stats
      end
    end
  end
end
