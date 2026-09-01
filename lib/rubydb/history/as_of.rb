# frozen_string_literal: true

require "time"

module RubyDB
  module History
    # AsOf - Handles AS OF queries (time travel)
    class AsOf
      attr_reader :stats

      def initialize(engine, history_manager, config = {})
        @engine = engine
        @history_manager = history_manager
        @config = config
        @stats = {
          as_of_queries: 0,
          as_of_restores: 0,
          snapshot_queries: 0,
          query_time_ms: 0,
          avg_query_time_ms: 0
        }
        @lock = Mutex.new
        @snapshot_cache = {}
        @cache_size = config[:cache_size] || 100
      end

      def as_of(table_name, time, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:as_of_queries] += 1

          # Parse time
          query_time = parse_time(time)

          # Get changes up to time
          changes = @history_manager.get_changes_for_table(table_name, query_time)

          # Reconstruct state
          result = reconstruct_state(table_name, changes, query_time, options)

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:as_of_queries]

          result
        end
      end

      def as_of_row(table_name, row_id, time)
        @lock.synchronize do
          start_time = Time.now
          @stats[:as_of_queries] += 1

          query_time = parse_time(time)
          changes = @history_manager.get_changes_for_row(table_name, row_id)

          # Find version at time
          version = find_version_at_time(changes, row_id, query_time)

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:as_of_queries]

          {
            row_id: row_id,
            table: table_name,
            as_of: query_time.iso8601,
            data: version,
            exists: !version.nil?
          }
        end
      end

      def as_of_snapshot(time, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:snapshot_queries] += 1

          query_time = parse_time(time)

          # Check cache
          cache_key = "snapshot_#{query_time.to_i}"
          if @snapshot_cache.key?(cache_key)
            return @snapshot_cache[cache_key]
          end

          # Get all changes up to time
          tables = options[:tables] || @engine.list_tables
          snapshot = {}

          tables.each do |table|
            changes = @history_manager.get_changes_for_table(table, query_time)
            snapshot[table] = reconstruct_state(table, changes, query_time)
          end

          result = {
            as_of: query_time.iso8601,
            snapshot: snapshot,
            tables: tables.size
          }

          # Cache snapshot
          if @snapshot_cache.size < @cache_size
            @snapshot_cache[cache_key] = result
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:snapshot_queries]

          result
        end
      end

      def restore_to_time(time, options = {})
        @lock.synchronize do
          start_time = Time.now
          @stats[:as_of_restores] += 1

          query_time = parse_time(time)

          # Get all changes up to time
          changes = @history_manager.get_changes_until(query_time)

          # Apply changes in reverse to reach desired state
          restore_changes = changes.reverse
          restore_changes.each do |change|
            undo_change(change)
          end

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:query_time_ms] += elapsed_ms
          @stats[:avg_query_time_ms] = @stats[:query_time_ms] / @stats[:as_of_restores]

          {
            success: true,
            restored_to: query_time.iso8601,
            changes_applied: changes.size
          }
        end
      end

      def clear_cache
        @lock.synchronize do
          @snapshot_cache.clear
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            cache_size: @snapshot_cache.size,
            max_cache_size: @cache_size
          })
        end
      end

      private

      def parse_time(time)
        case time
        when Time
          time
        when String
          Time.parse(time)
        when Integer
          Time.at(time)
        when DateTime
          time.to_time
        else
          raise ArgumentError, "Invalid time format: #{time}"
        end
      end

      def reconstruct_state(table_name, changes, time, options = {})
        rows = {}
        columns = options[:columns]

        changes.each do |change|
          case change.operation
          when Change::OP_INSERT
            rows[change.row_id] = change.new_values
          when Change::OP_UPDATE
            if rows.key?(change.row_id)
              rows[change.row_id] = rows[change.row_id].merge(change.new_values)
            else
              # Row might have been inserted before tracking started
              rows[change.row_id] = change.new_values
            end
          when Change::OP_DELETE
            rows.delete(change.row_id)
          end
        end

        # Apply column filter
        if columns
          rows.each do |row_id, data|
            rows[row_id] = data.select { |k| columns.include?(k) }
          end
        end

        {
          table: table_name,
          as_of: time.iso8601,
          rows: rows.values,
          count: rows.size
        }
      end

      def find_version_at_time(changes, row_id, time)
        current = nil

        changes.each do |change|
          if change.row_id == row_id && change.timestamp <= time
            if change.operation == Change::OP_DELETE
              current = nil
            elsif change.operation == Change::OP_UPDATE || change.operation == Change::OP_INSERT
              current = (current || {}).merge(change.new_values)
            end
          end
        end

        current
      end

      def undo_change(change)
        case change.operation
        when Change::OP_INSERT
          @engine.delete_row(change.table_name, change.row_id)
        when Change::OP_UPDATE
          @engine.update_row(change.table_name, change.row_id, change.old_values)
        when Change::OP_DELETE
          @engine.insert_row(change.table_name, change.old_values.keys, change.old_values)
        end
      end
    end
  end
end