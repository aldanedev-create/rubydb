# frozen_string_literal: true

require "time"

module RubyDB
  module History
    # History - Main history interface
    class History
      attr_reader :manager, :as_of, :temporal_query, :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @manager = HistoryManager.new(engine, config)
        @as_of = AsOf.new(engine, @manager, config)
        @temporal_query = TemporalQuery.new(engine, @manager, config)
        @stats = {
          operations: 0,
          records: 0,
          queries: 0,
          restores: 0
        }
        @lock = Mutex.new
      end

      def record(change_data)
        @lock.synchronize do
          change = Change.new(change_data)
          @manager.record_change(change)
          @stats[:records] += 1
          change
        end
      end

      def record_insert(table_name, row_id, values, options = {})
        record({
          table_name: table_name,
          row_id: row_id,
          operation: Change::OP_INSERT,
          new_values: values,
          user: options[:user],
          branch: options[:branch],
          transaction_id: options[:transaction_id]
        })
      end

      def record_update(table_name, row_id, old_values, new_values, options = {})
        record({
          table_name: table_name,
          row_id: row_id,
          operation: Change::OP_UPDATE,
          old_values: old_values,
          new_values: new_values,
          user: options[:user],
          branch: options[:branch],
          transaction_id: options[:transaction_id]
        })
      end

      def record_delete(table_name, row_id, old_values, options = {})
        record({
          table_name: table_name,
          row_id: row_id,
          operation: Change::OP_DELETE,
          old_values: old_values,
          user: options[:user],
          branch: options[:branch],
          transaction_id: options[:transaction_id]
        })
      end

      def query_as_of(table_name, time, columns = nil)
        @stats[:queries] += 1
        @as_of.as_of(table_name, time, columns: columns)
      end

      def query_between(table_name, start_time, end_time, columns = nil)
        @stats[:queries] += 1
        @temporal_query.query_between(table_name, start_time, end_time, columns)
      end

      def query_version(table_name, row_id, time)
        @stats[:queries] += 1
        @as_of.as_of_row(table_name, row_id, time)
      end

      def query_history(table_name, row_id)
        @stats[:queries] += 1
        @temporal_query.query_history(table_name, row_id)
      end

      def query_snapshot(time, options = {})
        @stats[:queries] += 1
        @as_of.as_of_snapshot(time, options)
      end

      def restore_to_time(time, options = {})
        @stats[:restores] += 1
        @as_of.restore_to_time(time, options)
      end

      def get_timeline(name = "main")
        @manager.get_timeline(name)
      end

      def delete_timeline(name)
        @manager.delete_timeline(name)
      end

      def prune(keep_count = nil)
        @manager.prune_history(keep_count)
      end

      def clear
        @manager.clear_history
        @as_of.clear_cache
        @temporal_query.clear_cache
      end

      def stats
        @lock.synchronize do
          @stats.merge(@manager.stats)
        end
      end

      def history_size
        @manager.history_size
      end
    end
  end
end