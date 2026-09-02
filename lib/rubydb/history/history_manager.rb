# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "monitor"

module RubyDB
  module History
    # HistoryManager - Manages all history operations
    class HistoryManager
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @history_dir = config[:history_dir] || "history"
        @max_history = config[:max_history] || 10000
        @retention_days = config[:retention_days] || 30
        @changes = []
        @timelines = {}
        @change_index = {}
        @stats = {
          changes_recorded: 0,
          changes_queried: 0,
          changes_deleted: 0,
          timelines_created: 0,
          timelines_deleted: 0,
          history_size: 0
        }
        @lock = Monitor.new

        FileUtils.mkdir_p(@history_dir)
        load_history
      end

      def record_change(change)
        @lock.synchronize do
          @changes << change
          @stats[:changes_recorded] += 1
          @stats[:history_size] = @changes.size

          # Update index
          @change_index[change.id] = change
          @change_index["#{change.table_name}:#{change.row_id}"] ||= []
          @change_index["#{change.table_name}:#{change.row_id}"] << change

          # Update timeline
          timeline_name = change.branch || "main"
          get_timeline(timeline_name).add_change(change)

          # Prune if needed
          prune_history if @changes.size > @max_history

          save_history
        end
      end

      def get_changes_for_table(table_name, time = nil)
        @lock.synchronize do
          @stats[:changes_queried] += 1

          changes = @changes.select do |c|
            c.table_name == table_name && (time.nil? || c.timestamp <= time)
          end

          changes.sort_by(&:timestamp)
        end
      end

      def get_changes_for_row(table_name, row_id)
        @lock.synchronize do
          @stats[:changes_queried] += 1
          @change_index["#{table_name}:#{row_id}"] || []
        end
      end

      def get_changes_between(table_name, start_time, end_time)
        @lock.synchronize do
          @stats[:changes_queried] += 1

          @changes.select do |c|
            c.table_name == table_name &&
            c.timestamp >= start_time &&
            c.timestamp <= end_time
          end
        end
      end

      def get_changes_until(time)
        @lock.synchronize do
          @stats[:changes_queried] += 1

          @changes.select { |c| c.timestamp <= time }
        end
      end

      def get_changes_by_user(user)
        @lock.synchronize do
          @stats[:changes_queried] += 1

          @changes.select { |c| c.user == user }
        end
      end

      def get_changes_by_branch(branch)
        @lock.synchronize do
          @stats[:changes_queried] += 1

          @changes.select { |c| c.branch == branch }
        end
      end

      def get_timeline(name)
        @lock.synchronize do
          @timelines[name] ||= Timeline.new(name)
        end
      end

      def delete_timeline(name)
        @lock.synchronize do
          timeline = @timelines.delete(name)
          @stats[:timelines_deleted] += 1 if timeline
          timeline
        end
      end

      def prune_history(keep_count = nil)
        @lock.synchronize do
          keep_count ||= @max_history

          if @changes.size > keep_count
            removed = @changes.shift(@changes.size - keep_count)
            @stats[:changes_deleted] += removed.size

            # Clean up index
            removed.each do |change|
              @change_index.delete(change.id)
              key = "#{change.table_name}:#{change.row_id}"
              if @change_index[key]
                @change_index[key].delete(change)
                @change_index.delete(key) if @change_index[key].empty?
              end
            end

            @stats[:history_size] = @changes.size
          end
        end
      end

      def clear_history
        @lock.synchronize do
          @changes.clear
          @change_index.clear
          @timelines.clear
          @stats[:history_size] = 0
          @stats[:changes_deleted] += 1
          save_history
        end
      end

      def history_size
        @changes.size
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            timelines: @timelines.size,
            max_history: @max_history,
            retention_days: @retention_days,
            history_dir: @history_dir
          })
        end
      end

      private

      def load_history
        history_file = File.join(@history_dir, "history.json")
        return unless File.exist?(history_file)

        begin
          data = JSON.parse(File.read(history_file), symbolize_names: true)

          data[:changes].each do |change_data|
            change = Change.from_json(change_data.to_json)
            @changes << change
            @change_index[change.id] = change
            key = "#{change.table_name}:#{change.row_id}"
            @change_index[key] ||= []
            @change_index[key] << change
          end

          data[:timelines].each do |name, timeline_data|
            timeline = Timeline.from_json(timeline_data.to_json)
            @timelines[name] = timeline
          end

          @stats[:changes_recorded] = data[:stats][:changes_recorded] || 0
          @stats[:history_size] = @changes.size

        rescue => e
          @changes = []
          @change_index = {}
          @timelines = {}
        end
      end

      def save_history
        data = {
          changes: @changes.map(&:to_hash),
          timelines: @timelines.transform_values(&:to_hash),
          stats: {
            changes_recorded: @stats[:changes_recorded],
            changes_deleted: @stats[:changes_deleted],
            timelines_created: @stats[:timelines_created],
            updated_at: Time.now.iso8601
          }
        }

        history_file = File.join(@history_dir, "history.json")
        temp_file = "#{history_file}.tmp"
        File.write(temp_file, JSON.generate(data))
        File.rename(temp_file, history_file)
      end
    end
  end
end
