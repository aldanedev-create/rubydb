# frozen_string_literal: true

module RubyDB
  module Execution
    # AggregateExecutor - Executes aggregate operations (GROUP BY, aggregate functions)
    class AggregateExecutor
      attr_reader :engine, :stats

      def initialize(engine)
        @engine = engine
        @stats = {
          aggregations: 0,
          groups_produced: 0,
          total_time_ms: 0
        }
        @lock = Mutex.new
      end

      def execute(plan, transaction_id = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:aggregations] += 1

          # Get input rows
          rows = plan.input_rows || []
          if rows.empty? && plan.input_plan
            executor = Executor.new(@engine)
            result = executor.execute(plan.input_plan, transaction_id)
            rows = result[:rows] if result
          end

          group_by = plan.group_by || []
          aggregates = plan.aggregates || []

          # Perform aggregation
          result = if group_by.empty?
            # Global aggregation
            aggregate_globally(rows, aggregates)
          else
            # Grouped aggregation
            aggregate_by_groups(rows, group_by, aggregates)
          end

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:groups_produced] += result.size
          @stats[:total_time_ms] += elapsed_ms

          {
            rows: result,
            row_count: result.size,
            groups: group_by,
            aggregates: aggregates,
            message: "AGGREGATE produced #{result.size} groups"
          }
        end
      end

      private

      def aggregate_globally(rows, aggregates)
        return [] if rows.empty? && aggregates.empty?

        result = {}
        
        aggregates.each do |agg|
          values = rows.map { |row| row[agg.column.to_s] }.compact
          result[agg.alias || agg.name] = apply_aggregate(agg, values)
        end

        [result]
      end

      def aggregate_by_groups(rows, group_by, aggregates)
        groups = {}
        
        rows.each do |row|
          # Build group key
          key = group_by.map { |col| row[col.to_s] }
          key_str = key.join("||")
          
          groups[key_str] ||= {
            key: key,
            rows: [],
            values: {}
          }
          groups[key_str][:rows] << row
        end

        result = []
        groups.each do |_key_str, group|
          row_result = {}
          
          # Add group by columns
          group_by.each_with_index do |col, idx|
            row_result[col.to_s] = group[:key][idx]
          end
          
          # Apply aggregates
          aggregates.each do |agg|
            values = group[:rows].map { |r| r[agg.column.to_s] }.compact
            row_result[agg.alias || agg.name] = apply_aggregate(agg, values)
          end
          
          result << row_result
        end
        
        result
      end

      def apply_aggregate(agg, values)
        case agg.name.to_s.upcase
        when "COUNT"
          values.size
        when "SUM"
          values.sum
        when "AVG"
          values.empty? ? 0 : values.sum / values.size.to_f
        when "MIN"
          values.min
        when "MAX"
          values.max
        when "GROUP_CONCAT"
          values.join(",")
        when "ARRAY_AGG"
          values
        when "STRING_AGG"
          values.join(agg.separator || ",")
        else
          nil
        end
      end

      def stats
        @stats
      end
    end
  end
end