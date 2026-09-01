# frozen_string_literal: true

module RubyDB
  module Monitoring
    # Performance - Performance monitoring
    class Performance
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @statistics = Statistics.new
        @metrics = {
          query_times: [],
          transaction_times: [],
          connection_times: [],
          wal_write_times: [],
          checkpoint_times: [],
          replication_lag: []
        }
        @query_counts = {}
        @slow_queries = []
        @max_slow_queries = config[:max_slow_queries] || 100
        @slow_query_threshold = config[:slow_query_threshold] || 1000
        @stats = {
          total_queries: 0,
          total_transactions: 0,
          avg_query_time: 0,
          slow_query_count: 0,
          transaction_throughput: 0,
          query_throughput: 0
        }
        @lock = Mutex.new
        @start_time = Time.now
      end

      def record_query(query, time_ms)
        @lock.synchronize do
          @stats[:total_queries] += 1
          @metrics[:query_times] << time_ms

          # Track query type
          type = extract_query_type(query)
          @query_counts[type] ||= 0
          @query_counts[type] += 1

          # Record slow queries
          if time_ms > @slow_query_threshold
            @slow_queries << {
              query: query,
              time_ms: time_ms,
              timestamp: Time.now.iso8601
            }
            @slow_queries = @slow_queries.last(@max_slow_queries)
            @stats[:slow_query_count] += 1
          end

          update_stats
        end
      end

      def record_transaction(time_ms)
        @lock.synchronize do
          @stats[:total_transactions] += 1
          @metrics[:transaction_times] << time_ms
          update_stats
        end
      end

      def record_connection(time_ms)
        @lock.synchronize do
          @metrics[:connection_times] << time_ms
          update_stats
        end
      end

      def record_wal_write(time_ms)
        @lock.synchronize do
          @metrics[:wal_write_times] << time_ms
          update_stats
        end
      end

      def record_checkpoint(time_ms)
        @lock.synchronize do
          @metrics[:checkpoint_times] << time_ms
          update_stats
        end
      end

      def record_replication_lag(lag_ms)
        @lock.synchronize do
          @metrics[:replication_lag] << lag_ms
          update_stats
        end
      end

      def query_performance
        @lock.synchronize do
          times = @metrics[:query_times]
          {
            total: @stats[:total_queries],
            avg: @statistics.mean(times),
            median: @statistics.median(times),
            p95: @statistics.percentile(times, 95),
            p99: @statistics.percentile(times, 99),
            min: @statistics.min(times),
            max: @statistics.max(times)
          }
        end
      end

      def transaction_performance
        @lock.synchronize do
          times = @metrics[:transaction_times]
          {
            total: @stats[:total_transactions],
            avg: @statistics.mean(times),
            median: @statistics.median(times),
            p95: @statistics.percentile(times, 95),
            p99: @statistics.percentile(times, 99),
            min: @statistics.min(times),
            max: @statistics.max(times)
          }
        end
      end

      def slow_queries
        @slow_queries.dup
      end

      def query_counts
        @query_counts.dup
      end

      def throughput
        @lock.synchronize do
          elapsed = (Time.now - @start_time).to_f
          {
            queries_per_second: @stats[:total_queries] / elapsed,
            transactions_per_second: @stats[:total_transactions] / elapsed
          }
        end
      end

      def stats
        @lock.synchronize do
          elapsed = (Time.now - @start_time).to_f
          @stats.merge({
            uptime_seconds: elapsed.round(2),
            query_stats: query_performance,
            transaction_stats: transaction_performance,
            throughput: throughput,
            slow_query_count: @slow_queries.size,
            query_types: @query_counts
          })
        end
      end

      private

      def extract_query_type(query)
        query.strip.split.first&.upcase || "UNKNOWN"
      end

      def update_stats
        times = @metrics[:query_times]
        @stats[:avg_query_time] = @statistics.mean(times) if times.any?

        elapsed = (Time.now - @start_time).to_f
        @stats[:query_throughput] = @stats[:total_queries] / elapsed if elapsed > 0
        @stats[:transaction_throughput] = @stats[:total_transactions] / elapsed if elapsed > 0
      end
    end
  end
end