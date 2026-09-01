# frozen_string_literal: true

require "set"

module RubyDB
  module Execution
    # DistinctExecutor - Executes DISTINCT operations
    class DistinctExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          distincts: 0,
          rows_input: 0,
          rows_output: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:distincts] += 1

          # Get input rows
          rows = plan.input_rows || []
          if rows.empty? && plan.input_plan
            executor = Executor.new(@engine)
            result = executor.execute(plan.input_plan, transaction_id)
            rows = result[:rows] if result
          end

          distinct_columns = plan.distinct_columns || []
          
          @stats[:rows_input] += rows.size

          # Perform distinct
          result_rows = if distinct_columns.empty?
            # Distinct on all columns
            distinct_all(rows)
          else
            # Distinct on specific columns
            distinct_on_columns(rows, distinct_columns)
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_output] += result_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: result_rows,
            row_count: result_rows.size,
            distinct_columns: distinct_columns,
            total_input: rows.size,
            message: "DISTINCT produced #{result_rows.size} rows"
          }
        end
      end

      def distinct_all(rows)
        seen = Set.new
        result = []

        rows.each do |row|
          # Create key from row values
          key = row.values_at(*row.keys).join("||")
          unless seen.include?(key)
            seen.add(key)
            result << row
          end
        end

        result
      end

      def distinct_on_columns(rows, columns)
        seen = Set.new
        result = []

        columns = columns.map(&:to_s)

        rows.each do |row|
          # Create key from specified columns
          key = columns.map { |col| row[col] }.join("||")
          unless seen.include?(key)
            seen.add(key)
            result << row
          end
        end

        result
      end

      # Optimized distinct using hash aggregation
      def distinct_using_hash(rows, columns = [])
        hash = {}
        columns = columns.map(&:to_s)

        rows.each do |row|
          key = if columns.empty?
            row.values_at(*row.keys).join("||")
          else
            columns.map { |col| row[col] }.join("||")
          end
          
          hash[key] = row unless hash.key?(key)
        end

        hash.values
      end

      # Distinct with ordering
      def distinct_with_order(rows, columns, order_by)
        distinct_rows = distinct_on_columns(rows, columns)
        
        # Sort results
        sort_executor = SortExecutor.new(@engine)
        sort_plan = Plan::Select.new(nil)
        sort_plan.input_rows = distinct_rows
        sort_plan.set_order_by(order_by)
        
        result = sort_executor.execute(sort_plan)
        result[:rows]
      end

      private

      def stats
        @stats
      end
    end
  end
end