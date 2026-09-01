# frozen_string_literal: true

module RubyDB
  module Execution
    # SortExecutor - Executes sorting operations
    class SortExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          sorts: 0,
          rows_sorted: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:sorts] += 1

          # Get input rows
          rows = plan.input_rows || []
          if rows.empty? && plan.input_plan
            executor = Executor.new(@engine)
            result = executor.execute(plan.input_plan, transaction_id)
            rows = result[:rows] if result
          end

          order_by = plan.order_by || []

          # Perform sorting
          sorted_rows = sort_rows(rows, order_by)

          # Apply limit if specified
          if plan.limit
            sorted_rows = sorted_rows.first(plan.limit)
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_sorted] += sorted_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: sorted_rows,
            row_count: sorted_rows.size,
            order_by: order_by,
            message: "SORT produced #{sorted_rows.size} rows"
          }
        end
      end

      def execute_external_sort(plan, temp_dir = nil, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:sorts] += 1

          # Get input rows
          rows = plan.input_rows || []
          if rows.empty? && plan.input_plan
            executor = Executor.new(@engine)
            result = executor.execute(plan.input_plan, transaction_id)
            rows = result[:rows] if result
          end

          order_by = plan.order_by || []

          # External sort for large datasets
          sorted_rows = external_sort(rows, order_by, temp_dir)

          # Apply limit if specified
          if plan.limit
            sorted_rows = sorted_rows.first(plan.limit)
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_sorted] += sorted_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: sorted_rows,
            row_count: sorted_rows.size,
            order_by: order_by,
            message: "EXTERNAL SORT produced #{sorted_rows.size} rows"
          }
        end
      end

      private

      def sort_rows(rows, order_by)
        return rows if order_by.empty?

        rows.sort do |a, b|
          comparison = 0
          order_by.each do |order|
            col = order.column.to_s
            val_a = a[col]
            val_b = b[col]

            comparison = compare_values(val_a, val_b)
            comparison = -comparison if order.direction == :desc
            break unless comparison == 0
          end
          comparison
        end
      end

      def compare_values(a, b)
        return 0 if a.nil? && b.nil?
        return -1 if a.nil?
        return 1 if b.nil?

        if a.is_a?(String) && b.is_a?(String)
          a <=> b
        else
          a <=> b
        end
      end

      def external_sort(rows, order_by, temp_dir)
        # For large datasets, sort in chunks
        chunk_size = 10000
        chunks = []
        
        rows.each_slice(chunk_size) do |chunk|
          chunks << sort_rows(chunk, order_by)
        end

        # Merge sorted chunks
        merge_sorted_chunks(chunks, order_by)
      end

      def merge_sorted_chunks(chunks, order_by)
        return [] if chunks.empty?
        return chunks.first if chunks.size == 1

        result = []
        indices = Array.new(chunks.size, 0)

        loop do
          min_index = nil
          min_value = nil
          min_row = nil

          chunks.each_with_index do |chunk, idx|
            pos = indices[idx]
            next if pos >= chunk.size

            row = chunk[pos]
            if min_value.nil? || compare_rows(row, min_row, order_by) < 0
              min_index = idx
              min_value = row
              min_row = row
            end
          end

          break if min_index.nil?

          result << min_row
          indices[min_index] += 1
        end

        result
      end

      def compare_rows(a, b, order_by)
        order_by.each do |order|
          col = order.column.to_s
          val_a = a[col]
          val_b = b[col]
          comparison = compare_values(val_a, val_b)
          return comparison unless comparison == 0
        end
        0
      end

      def stats
        @stats
      end
    end
  end
end