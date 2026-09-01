# frozen_string_literal: true

module RubyDB
  module Execution
    # InsertExecutor - Executes INSERT operations
    class InsertExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          inserts: 0,
          rows_inserted: 0,
          conflicts: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:inserts] += 1

          table_name = plan.table_name
          columns = plan.columns
          values = plan.values

          # Get table columns
          table_columns = @engine.table_columns(table_name)
          raise ExecutionError, "Table '#{table_name}' does not exist" if table_columns.empty?

          # Handle different value formats
          rows_to_insert = prepare_rows(columns, values, table_columns)

          # Check constraints
          validate_constraints(table_name, rows_to_insert)

          # Check for conflicts (if ON CONFLICT specified)
          conflict_action = plan.options[:on_conflict] || :error
          conflict_handled = false

          if conflict_action != :error && plan.conflict_columns
            rows_to_insert = handle_conflicts(table_name, rows_to_insert, conflict_action, plan.conflict_columns)
            conflict_handled = true
          end

          # Insert rows
          inserted_rows = []
          rows_to_insert.each do |row_data|
            row_id = @engine.insert_row(table_name, table_columns, row_data)
            
            # Update indexes
            if @engine.respond_to?(:index_manager)
              row = row_data.merge("_row_id" => row_id)
              @engine.index_manager.insert_row(table_name, row)
            end

            inserted_rows << { row_id: row_id, row: row_data }
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_inserted] += inserted_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: inserted_rows,
            row_count: inserted_rows.size,
            row_ids: inserted_rows.map { |r| r[:row_id] },
            message: "INSERT #{inserted_rows.size}",
            conflict_handled: conflict_handled
          }
        end
      end

      def execute_batch(plan, rows, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:inserts] += 1

          table_name = plan.table_name
          table_columns = @engine.table_columns(table_name)
          raise ExecutionError, "Table '#{table_name}' does not exist" if table_columns.empty?

          prepared_rows = rows.map do |row|
            prepare_single_row(plan.columns, row, table_columns)
          end

          # Bulk insert
          inserted_rows = []
          prepared_rows.each do |row_data|
            row_id = @engine.insert_row(table_name, table_columns, row_data)
            
            if @engine.respond_to?(:index_manager)
              row = row_data.merge("_row_id" => row_id)
              @engine.index_manager.insert_row(table_name, row)
            end

            inserted_rows << { row_id: row_id, row: row_data }
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_inserted] += inserted_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: inserted_rows,
            row_count: inserted_rows.size,
            row_ids: inserted_rows.map { |r| r[:row_id] },
            message: "INSERT #{inserted_rows.size}"
          }
        end
      end

      private

      def prepare_rows(columns, values, table_columns)
        return [] if values.empty?

        # If values is a single array, treat as one row
        if values.first.is_a?(Array) || values.first.is_a?(Hash)
          values.map { |v| prepare_single_row(columns, v, table_columns) }
        else
          [prepare_single_row(columns, values, table_columns)]
        end
      end

      def prepare_single_row(columns, values, table_columns)
        row_data = {}

        if values.is_a?(Hash)
          # Values provided as hash
          values.each do |key, val|
            row_data[key.to_s] = val
          end
        elsif values.is_a?(Array)
          # Values provided as array - match by position
          columns.each_with_index do |col, idx|
            row_data[col.to_s] = values[idx] if idx < values.size
          end
        else
          # Single value - use first column
          row_data[columns.first.to_s] = values if columns.any?
        end

        # Add default values for missing columns
        table_columns.each do |col|
          unless row_data.key?(col.name)
            row_data[col.name] = col.default if col.has_default?
          end
        end

        row_data
      end

      def validate_constraints(table_name, rows)
        # Check NOT NULL constraints
        table_columns = @engine.table_columns(table_name)
        rows.each do |row|
          table_columns.each do |col|
            if !col.nullable? && row[col.name].nil?
              raise ConstraintError, "Column '#{col.name}' cannot be NULL"
            end
          end
        end
      end

      def handle_conflicts(table_name, rows, conflict_action, conflict_columns)
        handled_rows = []
        conflict_columns = conflict_columns.map(&:to_s)

        rows.each do |row|
          # Check if row conflicts with existing data
          conflict = find_conflict(table_name, row, conflict_columns)

          if conflict
            @stats[:conflicts] += 1
            if conflict_action == :ignore
              next
            elsif conflict_action == :update
              # Update existing row with new values
              update_conflict_row(table_name, conflict, row)
              next
            end
          end

          handled_rows << row
        end

        handled_rows
      end

      def find_conflict(table_name, row, conflict_columns)
        # Check if any row exists with the same conflicting columns
        conditions = {}
        conflict_columns.each do |col|
          conditions[col] = row[col] if row.key?(col)
        end

        return nil if conditions.empty?

        table_columns = @engine.table_columns(table_name)
        rows = @engine.select_rows(table_name, table_columns, conditions)
        rows.first
      end

      def update_conflict_row(table_name, existing_row, new_row)
        row_id = existing_row[:_row_id] || existing_row["_row_id"]
        @engine.update_row(table_name, row_id, new_row)
      end

      def stats
        @stats
      end
    end
  end
end