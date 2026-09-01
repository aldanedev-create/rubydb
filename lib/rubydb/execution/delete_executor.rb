# frozen_string_literal: true

module RubyDB
  module Execution
    # DeleteExecutor - Executes DELETE operations
    class DeleteExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          deletes: 0,
          rows_deleted: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:deletes] += 1

          table_name = plan.table_name
          predicate = plan.predicate

          # Get table columns
          table_columns = @engine.table_columns(table_name)
          raise ExecutionError, "Table '#{table_name}' does not exist" if table_columns.empty?

          # Find rows to delete
          rows = find_rows(table_name, predicate)

          deleted_count = 0
          deleted_rows = []

          rows.each do |row|
            row_id = row[:_row_id] || row["_row_id"] || row[:id] || row["id"]

            # Delete from engine
            @engine.delete_row(table_name, row_id, transaction_id: transaction_id)

            # Remove from indexes
            if @engine.respond_to?(:index_manager)
              @engine.index_manager.delete_row(table_name, row)
            end

            deleted_count += 1
            deleted_rows << row
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_deleted] += deleted_count
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: deleted_rows,
            row_count: deleted_count,
            row_ids: deleted_rows.map { |r| r[:_row_id] || r["_row_id"] },
            message: "DELETE #{deleted_count}"
          }
        end
      end

      def execute_batch(plan, row_ids, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:deletes] += 1

          table_name = plan.table_name
          table_columns = @engine.table_columns(table_name)

          deleted_count = 0
          deleted_rows = []

          row_ids.each do |row_id|
            row = @engine.select_row(table_name, row_id, table_columns)
            next unless row

            @engine.delete_row(table_name, row_id, transaction_id: transaction_id)

            if @engine.respond_to?(:index_manager)
              @engine.index_manager.delete_row(table_name, row)
            end

            deleted_count += 1
            deleted_rows << row
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_deleted] += deleted_count
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: deleted_rows,
            row_count: deleted_count,
            row_ids: row_ids,
            message: "DELETE #{deleted_count}"
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

      def stats
        @stats
      end
    end
  end
end