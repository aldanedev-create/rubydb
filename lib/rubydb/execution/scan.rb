# frozen_string_literal: true

module RubyDB
  module Execution
    # Scan - Base class for table scans
    class Scan
      attr_reader :plan, :stats

      def initialize(plan)
        @plan = plan
        @stats = {
          rows_scanned: 0,
          rows_returned: 0,
          pages_accessed: 0,
          scan_time_ms: 0
        }
        @position = 0
        @results = nil
        @executed = false
      end

      def execute
        raise NotImplementedError
      end

      def next
        return nil if @results.nil? || @position >= @results.size

        result = @results[@position]
        @position += 1
        result
      end

      def reset
        @position = 0
        @results = nil
        @executed = false
      end

      def count
        @results ? @results.size : 0
      end

      def scan_stats
        @stats
      end
    end
  end
end