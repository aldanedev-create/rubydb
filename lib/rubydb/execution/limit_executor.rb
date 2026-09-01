# frozen_string_literal: true

module RubyDB
  module Execution
    # LimitExecutor - Executes LIMIT and OFFSET operations
    class LimitExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          limits: 0,
          rows_returned: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:limits] += 1

          # Get input rows
          rows = plan.input_rows || []
          if rows.empty? && plan.input_plan
            executor = Executor.new(@engine)
            result = executor.execute(plan.input_plan, transaction_id)
            rows = result[:rows] if result
          end

          limit = plan.limit
          offset = plan.offset || 0

          # Apply limit and offset
          result_rows = if limit
            rows[offset, limit] || []
          elsif offset > 0
            rows[offset..-1] || []
          else
            rows
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_returned] += result_rows.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: result_rows,
            row_count: result_rows.size,
            limit: limit,
            offset: offset,
            total_rows: rows.size,
            message: "LIMIT #{limit} OFFSET #{offset} produced #{result_rows.size} rows"
          }
        end
      end

      def execute_with_count(plan, transaction_id = nil)
        result = execute(plan, transaction_id)
        
        # Also get total count without limit
        if plan.input_plan
          count_plan = plan.input_plan.dup
          count_plan.set_limit(nil)
          count_plan.set_offset(nil)
          
          executor = Executor.new(@engine)
          count_result = executor.execute(count_plan, transaction_id)
          result[:total_available] = count_result[:row_count]
        else
          result[:total_available] = result[:total_rows]
        end
        
        result
      end

      private

      def stats
        @stats
      end
    end
  end
end