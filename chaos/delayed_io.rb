# frozen_string_literal: true

module RubyDB
  module Chaos
    # DelayedIO - Simulates delayed I/O operations
    class DelayedIO
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @delay_probability = config[:probability] || 0.1
        @min_delay_ms = config[:min_delay] || 10
        @max_delay_ms = config[:max_delay] || 1000
        @delay_on_operation = config[:on_operation] || :any
        @stats = {
          delays: 0,
          total_delay_ms: 0,
          avg_delay_ms: 0,
          max_delay_ms: 0,
          operations_affected: [],
          last_delay: nil
        }
        @lock = Mutex.new
        @intercept_io = false
      end

      def inject(operation = nil)
        @lock.synchronize do
          if should_delay?(operation)
            perform_delay
          end
        end
      end

      def delay_operation(operation, ms = nil)
        @lock.synchronize do
          ms ||= rand(@min_delay_ms..@max_delay_ms)
          @stats[:delays] += 1
          @stats[:total_delay_ms] += ms
          @stats[:max_delay_ms] = [@stats[:max_delay_ms], ms].max
          @stats[:avg_delay_ms] = @stats[:total_delay_ms] / @stats[:delays]
          @stats[:last_delay] = { time: Time.now, operation: operation, ms: ms }
          @stats[:operations_affected] << operation unless @stats[:operations_affected].include?(operation)

          sleep(ms / 1000.0)
        end
      end

      def enable_intercept
        @lock.synchronize do
          @intercept_io = true
        end
      end

      def disable_intercept
        @lock.synchronize do
          @intercept_io = false
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            delay_probability: @delay_probability,
            min_delay_ms: @min_delay_ms,
            max_delay_ms: @max_delay_ms,
            delay_on_operation: @delay_on_operation,
            intercepting: @intercept_io
          })
        end
      end

      private

      def should_delay?(operation)
        return false unless @delay_on_operation == :any || @delay_on_operation == operation
        rand < @delay_probability
      end

      def perform_delay
        delay_ms = rand(@min_delay_ms..@max_delay_ms)
        delay_operation(:io, delay_ms)
      end
    end
  end
end