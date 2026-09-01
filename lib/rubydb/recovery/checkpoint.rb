# frozen_string_literal: true

require "time"

module RubyDB
  module Recovery
    # Checkpoint - Manages recovery checkpoints
    class Checkpoint
      attr_reader :last_checkpoint, :stats

      def initialize(engine, wal, config = {})
        @engine = engine
        @wal = wal
        @config = config
        @last_checkpoint = nil
        @checkpoint_history = []
        @max_history = config[:max_history] || 100
        @stats = {
          checkpoints_created: 0,
          checkpoints_restored: 0,
          checkpoint_failures: 0,
          total_checkpoint_time_ms: 0,
          avg_checkpoint_time_ms: 0,
          last_checkpoint_size: 0
        }
        @lock = Mutex.new

        # Load checkpoint history
        load_checkpoint_history
      end

      def create_checkpoint(force = false)
        @lock.synchronize do
          start_time = Time.now

          begin
            # Flush all pending changes
            @engine.flush
            @wal.flush

            # Get current state
            current_state = capture_current_state

            # Create checkpoint record
            checkpoint_data = {
              lsn: @wal.current_lsn.to_s,
              timestamp: Time.now.iso8601,
              wal_segment: @wal.writer.current_segment.segment_id,
              wal_offset: @wal.current_lsn.offset,
              state: current_state,
              tables: list_tables,
              sequences: list_sequences,
              indexes: list_indexes,
              transaction_count: active_transaction_count
            }

            # Write checkpoint record to WAL
            record = Record.new(:checkpoint, checkpoint_data)
            @wal.write(record)

            # Update checkpoint info
            @last_checkpoint = checkpoint_data
            @checkpoint_history << checkpoint_data

            # Trim history
            if @checkpoint_history.size > @max_history
              @checkpoint_history.shift
            end

            # Save checkpoint history
            save_checkpoint_history

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:checkpoints_created] += 1
            @stats[:total_checkpoint_time_ms] += elapsed_ms
            @stats[:avg_checkpoint_time_ms] = @stats[:total_checkpoint_time_ms] / @stats[:checkpoints_created]
            @stats[:last_checkpoint_size] = estimate_checkpoint_size

            true

          rescue => e
            @stats[:checkpoint_failures] += 1
            raise
          end
        end
      end

      def restore_checkpoint
        @lock.synchronize do
          start_time = Time.now

          begin
            # Find the latest checkpoint in the WAL
            all_records = @wal.read_all
            checkpoint_records = all_records.select { |r| r.type == :checkpoint }

            if checkpoint_records.empty?
              return nil
            end

            # Get the latest checkpoint
            latest = checkpoint_records.last
            checkpoint_data = latest.data

            @last_checkpoint = checkpoint_data
            @stats[:checkpoints_restored] += 1

            checkpoint_data

          rescue => e
            @stats[:checkpoint_failures] += 1
            raise
          end
        end
      end

      def list_checkpoints
        @checkpoint_history.dup
      end

      def checkpoint_exists?
        !@last_checkpoint.nil?
      end

      def checkpoint_age
        return nil unless @last_checkpoint
        Time.now - Time.parse(@last_checkpoint[:timestamp])
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            last_checkpoint: @last_checkpoint,
            checkpoint_age: checkpoint_age,
            history_size: @checkpoint_history.size,
            max_history: @max_history
          })
        end
      end

      private

      def capture_current_state
        {
          active_transactions: active_transactions,
          committed_transactions: committed_transactions,
          sequences: sequence_values,
          database_version: database_version,
          last_operation_time: Time.now.iso8601
        }
      end

      def active_transactions
        # Get active transaction IDs
        if @engine.respond_to?(:transaction_manager)
          @engine.transaction_manager.active_transactions.keys
        else
          []
        end
      end

      def active_transaction_count
        active_transactions.size
      end

      def committed_transactions
        if @engine.respond_to?(:transaction_manager)
          @engine.transaction_manager.committed_transactions.map { |t| t.id }
        else
          []
        end
      end

      def sequence_values
        # Get current sequence values
        if @engine.respond_to?(:catalog)
          values = {}
          @engine.catalog.sequences.each do |name, seq|
            values[name] = seq.current_value
          end
          values
        else
          {}
        end
      end

      def database_version
        @engine.respond_to?(:version) ? @engine.version : "1.0"
      end

      def list_tables
        @engine.list_tables rescue []
      end

      def list_sequences
        if @engine.respond_to?(:catalog)
          @engine.catalog.sequences.keys
        else
          []
        end
      end

      def list_indexes
        if @engine.respond_to?(:index_manager)
          @engine.index_manager.indexes.keys
        else
          []
        end
      end

      def estimate_checkpoint_size
        # Estimate checkpoint size in bytes
        tables = list_tables
        size = 1024  # Base overhead

        tables.each do |table|
          row_count = @engine.table_row_count(table) rescue 0
          size += row_count * 100  # Rough estimate per row
        end

        size
      end

      def load_checkpoint_history
        @lock.synchronize do
          history_path = checkpoint_history_path
          if File.exist?(history_path)
            data = File.read(history_path)
            parsed = JSON.parse(data, symbolize_names: true)
            @checkpoint_history = parsed[:history] || []
            @last_checkpoint = parsed[:last_checkpoint]
          end
        end
      rescue
        @checkpoint_history = []
      end

      def save_checkpoint_history
        @lock.synchronize do
          data = {
            history: @checkpoint_history,
            last_checkpoint: @last_checkpoint,
            timestamp: Time.now.iso8601
          }
          File.write(checkpoint_history_path, JSON.generate(data))
        end
      end

      def checkpoint_history_path
        @checkpoint_history_path ||= File.join(
          @engine.instance_variable_get(:@path),
          "checkpoint_history.json"
        )
      end
    end
  end
end