# frozen_string_literal: true

module RubyDB
  module Execution
    # SequentialScan - Scans a table sequentially
    class SequentialScan < Scan
      attr_reader :engine

      def initialize(engine, plan)
        super(plan)
        @engine = engine
        @filtered_rows = nil
      end

      def execute
        start_time = Time.now

        table_name = @plan.table_name
        columns = @engine.table_columns(table_name)

        # Get all rows
        rows = @engine.select_rows(table_name, columns)
        @stats[:rows_scanned] = rows.size
        @stats[:pages_accessed] = (rows.size / 100.0).ceil + 1

        # Apply predicate if present
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