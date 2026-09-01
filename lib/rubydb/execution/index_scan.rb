# frozen_string_literal: true

module RubyDB
  module Execution
    # IndexScan - Scans a table using an index
    class IndexScan < Scan
      attr_reader :engine, :index

      def initialize(engine, plan)
        super(plan)
        @engine = engine
        @index = plan.index
        @index_scan = nil
      end

      def execute
        start_time = Time.now

        table_name = @plan.table_name
        columns = @engine.table_columns(table_name)

        # Create index scan
        @index_scan = Indexes::IndexScan.new(
          @index,
          determine_scan_type,
          build_scan_conditions
        )

        # Execute index scan
        index_results = @index_scan.execute
        @stats[:rows_scanned] = index_results.size
        @stats[:pages_accessed] = @index_scan.stats[:index_pages_accessed] || 1

        # Fetch rows by row_id
        rows = []
        index_results.each do |result|
          row_id = result[:row_id]
          row = @engine.select_row(table_name, row_id, columns)
          rows << row if row
        end

        # Apply predicate if present (additional filtering)
        if @plan.predicate
          rows = rows.select do |row|
            @plan.predicate.evaluate(row)
          end
        end

        # Apply projections
        if @plan.projections
          rows = rows.map do |row|
            project_row(row)
          end
        end

        @results = rows
        @stats[:rows_returned] = rows.size
        @stats[:scan_time_ms] = ((Time.now - start_time) * 1000).round(2)
        @executed = true

        @results
      end

      private

      def determine_scan_type
        return :full unless @plan.predicate

        # Try to determine scan type from predicate
        case @plan.predicate
        when Predicate::Comparison
          case @plan.predicate.operator
          when :eq then :equal
          when :lt, :lte, :gt, :gte then :range
          else :full
          end
        when Predicate::Like
          :prefix
        when Predicate::Between
          :range
        when Predicate::In
          :multi_key
        else
          :full
        end
      end

      def build_scan_conditions
        return {} unless @plan.predicate

        case @plan.predicate
        when Predicate::Comparison
          build_comparison_conditions(@plan.predicate)
        when Predicate::Between
          {
            start_key: @plan.predicate.low,
            end_key: @plan.predicate.high
          }
        when Predicate::In
          {
            keys: @plan.predicate.values
          }
        when Predicate::Like
          {
            prefix: @plan.predicate.pattern.value
          }
        else
          {}
        end
      end

      def build_comparison_conditions(predicate)
        case predicate.operator
        when :eq
          { key: predicate.right.value }
        when :lt
          { end_key: predicate.right.value, inclusive_end: false }
        when :lte
          { end_key: predicate.right.value, inclusive_end: true }
        when :gt
          { start_key: predicate.right.value, inclusive_start: false }
        when :gte
          { start_key: predicate.right.value, inclusive_start: true }
        else
          {}
        end
      end

      def project_row(row)
        result = {}
        @plan.projections.each do |proj|
          if proj.is_a?(String) || proj.is_a?(Symbol)
            result[proj.to_s] = row[proj.to_s]
          elsif proj.respond_to?(:evaluate)
            result[proj.alias || proj.to_s] = proj.evaluate(row)
          end
        end
        result
      end
    end
  end
end