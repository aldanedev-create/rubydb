# frozen_string_literal: true

require "monitor"

module RubyDB
  module History
    # TemporalQuery - Executes temporal queries against history
    class TemporalQuery
      attr_reader :stats

      def initialize(engine, history_manager, config = {})
        @engine = engine
        @history_manager = history_manager
        @config = config
        @stats = {
          queries: 0,
          temporal_queries: 0,
          as_of_queries: 0,
          between_queries: 0,
          query_time_ms: 0,
          avg_query_time_ms: 0
        }
        @lock = Monitor.new
        @result_cache = {}
        @cache_size = config[:cache_size] || 1000
      end

      def query_as_of(table_name, time, columns = nil)
        @lock.synchronize do
          started_at = Time.now
          @stats[:queries] += 1
          @stats[:as_of_queries] += 1

          cache_key = "as_of_#{table_name}_#{time.to_i}_#{columns&.join('_')}"
          if @result_cache.key?(cache_key)
            return @result_cache[cache_key]
          end

          # Get history for the table
          changes = @history_manager.get_changes_for_table(table_name, time)

          # Reconstruct state at time
          result = reconstruct_state(changes, time, columns)

          # Cache result
          if @result_cache.size < @cache_size
            @result_cache[cache_key] = result
          end

          elapsed_ms = (Time.now - started_at) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:queries]

          result
        end
      end

      def query_between(table_name, start_time, end_time, columns = nil)
        @lock.synchronize do
          started_at = Time.now
          @stats[:queries] += 1
          @stats[:between_queries] += 1

          # Get changes between times
          changes = @history_manager.get_changes_between(table_name, start_time, end_time)

          # Apply changes and return results
          results = apply_changes(changes, start_time, end_time, columns)

          elapsed_ms = (Time.now - started_at) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:queries]

          results
        end
      end

      def query_temporal(table_name, time, columns = nil)
        query_as_of(table_name, time, columns)
      end

      def query_version(table_name, row_id, version_time)
        @lock.synchronize do
          started_at = Time.now
          @stats[:queries] += 1
          @stats[:temporal_queries] += 1

          changes = @history_manager.get_changes_for_row(table_name, row_id)

          # Find version at time
          version = find_version_at_time(changes, row_id, version_time)

          elapsed_ms = (Time.now - started_at) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:queries]

          version
        end
      end

      def query_history(table_name, row_id)
        @lock.synchronize do
          @stats[:queries] += 1

          changes = @history_manager.get_changes_for_row(table_name, row_id)

          {
            row_id: row_id,
            table: table_name,
            history: changes.map(&:to_hash)
          }
        end
      end

      def clear_cache
        @lock.synchronize do
          @result_cache.clear
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            cache_size: @result_cache.size,
            max_cache_size: @cache_size
          })
        end
      end

      private

      def reconstruct_state(changes, time, columns)
        # Reconstruct the state at a point in time
        rows = {}
        changes.each do |change|
          case change.operation
          when Change::OP_INSERT
            rows[change.row_id] = change.new_values
          when Change::OP_UPDATE
            if rows.key?(change.row_id)
              rows[change.row_id] = rows[change.row_id].merge(change.new_values)
            end
          when Change::OP_DELETE
            rows.delete(change.row_id)
          end
        end

        {
          table: changes.first&.table_name,
          as_of: time.iso8601,
          rows: columns ? rows.values.map { |r| r.select { |k| columns.include?(k) } } : rows.values,
          count: rows.size
        }
      end

      def apply_changes(changes, start_time, end_time, columns)
        results = []
        current_state = {}

        changes.each do |change|
          case change.operation
          when Change::OP_INSERT
            current_state[change.row_id] = change.new_values
          when Change::OP_UPDATE
            if current_state.key?(change.row_id)
              current_state[change.row_id] = current_state[change.row_id].merge(change.new_values)
            end
          when Change::OP_DELETE
            current_state.delete(change.row_id)
          end

          # Record state at this point
          if change.timestamp >= start_time && change.timestamp <= end_time
            results << {
              timestamp: change.timestamp.iso8601,
              operation: change.operation,
              row_id: change.row_id,
              data: columns ? change.new_values.select { |k| columns.include?(k) } : change.new_values
            }
          end
        end

        results
      end

      def find_version_at_time(changes, row_id, time)
        # Find the version of a row at a specific time
        current = nil
        changes.each do |change|
          if change.row_id == row_id && change.timestamp <= time
            if change.operation == Change::OP_DELETE
              current = nil
            else
              current = change.new_values.dup
            end
          end
        end
        current
      end
    end
  end
end
