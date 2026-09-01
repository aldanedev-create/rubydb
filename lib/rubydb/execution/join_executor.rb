# frozen_string_literal: true

module RubyDB
  module Execution
    # JoinExecutor - Executes JOIN operations
    class JoinExecutor
      attr_reader :engine, :stats

      # Join types
      INNER_JOIN = :inner
      LEFT_JOIN = :left
      RIGHT_JOIN = :right
      FULL_JOIN = :full
      CROSS_JOIN = :cross

      def initialize(engine)
        @engine = engine
        @stats = {
          joins: 0,
          rows_produced: 0,
          total_time_ms: 0,
          join_type_counts: Hash.new(0)
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:joins] += 1
          @stats[:join_type_counts][plan.join_type] += 1

          left_rows = plan.left_rows || []
          right_rows = plan.right_rows || []

          # If no rows provided, execute sub-plans
          if left_rows.empty? && plan.left_plan
            left_executor = Executor.new(@engine)
            left_result = left_executor.execute(plan.left_plan, transaction_id)
            left_rows = left_result[:rows] if left_result
          end

          if right_rows.empty? && plan.right_plan
            right_executor = Executor.new(@engine)
            right_result = right_executor.execute(plan.right_plan, transaction_id)
            right_rows = right_result[:rows] if right_result
          end

          # Perform join
          result = case plan.join_type
          when INNER_JOIN
            inner_join(left_rows, right_rows, plan.join_condition)
          when LEFT_JOIN
            left_join(left_rows, right_rows, plan.join_condition)
          when RIGHT_JOIN
            right_join(left_rows, right_rows, plan.join_condition)
          when FULL_JOIN
            full_join(left_rows, right_rows, plan.join_condition)
          when CROSS_JOIN
            cross_join(left_rows, right_rows)
          else
            inner_join(left_rows, right_rows, plan.join_condition)
          end

          # Apply projections if specified
          if plan.projections
            result = result.map do |row|
              project_row(row, plan.projections)
            end
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:rows_produced] += result.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: result,
            row_count: result.size,
            left_rows: left_rows.size,
            right_rows: right_rows.size,
            message: "#{plan.join_type.to_s.upcase} JOIN produced #{result.size} rows"
          }
        end
      end

      def inner_join(left_rows, right_rows, condition)
        return [] if left_rows.empty? || right_rows.empty?
        return cross_join(left_rows, right_rows) if condition.nil?

        result = []
        left_rows.each do |left_row|
          right_rows.each do |right_row|
            if evaluate_join_condition(condition, left_row, right_row)
              result << merge_rows(left_row, right_row)
            end
          end
        end
        result
      end

      def left_join(left_rows, right_rows, condition)
        result = []
        left_rows.each do |left_row|
          matched = false
          right_rows.each do |right_row|
            if evaluate_join_condition(condition, left_row, right_row)
              result << merge_rows(left_row, right_row)
              matched = true
            end
          end
          unless matched
            result << merge_rows(left_row, nil)
          end
        end
        result
      end

      def right_join(left_rows, right_rows, condition)
        result = []
        right_rows.each do |right_row|
          matched = false
          left_rows.each do |left_row|
            if evaluate_join_condition(condition, left_row, right_row)
              result << merge_rows(left_row, right_row)
              matched = true
            end
          end
          unless matched
            result << merge_rows(nil, right_row)
          end
        end
        result
      end

      def full_join(left_rows, right_rows, condition)
        # Left join
        left_result = left_join(left_rows, right_rows, condition)
        
        # Right join (only rows not already matched)
        right_rows.each do |right_row|
          matched = left_result.any? do |row|
            row["_right_row"] && row["_right_row"] == right_row
          end
          unless matched
            left_result << merge_rows(nil, right_row)
          end
        end
        
        left_result
      end

      def cross_join(left_rows, right_rows)
        result = []
        left_rows.each do |left_row|
          right_rows.each do |right_row|
            result << merge_rows(left_row, right_row)
          end
        end
        result
      end

      def hash_join(left_rows, right_rows, condition)
        # Build hash table on right side
        hash_table = {}
        right_rows.each do |right_row|
          key = extract_join_key(right_row, condition)
          hash_table[key] ||= []
          hash_table[key] << right_row
        end

        result = []
        left_rows.each do |left_row|
          key = extract_join_key(left_row, condition)
          if hash_table.key?(key)
            hash_table[key].each do |right_row|
              if evaluate_join_condition(condition, left_row, right_row)
                result << merge_rows(left_row, right_row)
              end
            end
          end
        end
        result
      end

      def nested_loop_join(left_rows, right_rows, condition)
        result = []
        left_rows.each do |left_row|
          right_rows.each do |right_row|
            if evaluate_join_condition(condition, left_row, right_row)
              result << merge_rows(left_row, right_row)
            end
          end
        end
        result
      end

      private

      def evaluate_join_condition(condition, left_row, right_row)
        return true if condition.nil?
        
        # Bind row context
        context = { "_left" => left_row, "_right" => right_row }
        condition.evaluate(context)
      end

      def extract_join_key(row, condition)
        # Extract key from condition for hash join
        # Simplified - in production would extract column references
        row.object_id
      end

      def merge_rows(left_row, right_row)
        result = {}
        
        # Add left row with prefix
        if left_row
          left_row.each do |key, value|
            result["_left_#{key}"] = value
            result[key] = value unless result.key?(key)
          end
        end
        
        # Add right row with prefix
        if right_row
          right_row.each do |key, value|
            result["_right_#{key}"] = value
            result[key] = value unless result.key?(key)
          end
        end
        
        # Store original rows for reference
        result["_left_row"] = left_row
        result["_right_row"] = right_row
        
        result
      end

      def project_row(row, projections)
        result = {}
        projections.each do |proj|
          if proj.is_a?(String) || proj.is_a?(Symbol)
            result[proj.to_s] = row[proj.to_s]
          elsif proj.respond_to?(:evaluate)
            result[proj.alias || proj.to_s] = proj.evaluate(row)
          end
        end
        result
      end

      def stats
        @stats
      end
    end
  end
end