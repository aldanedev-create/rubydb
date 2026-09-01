# frozen_string_literal: true

require "json"
require "fileutils"

# Import transaction for serialization
require_relative "transaction"

module RubyDB
  module Transactions
    # TransactionLog - Logs transaction operations for recovery
    class TransactionLog
      attr_reader :log_path, :stats

      # Log entry types
      ENTRY_START = :start
      ENTRY_PREPARE = :prepare
      ENTRY_COMMIT = :commit
      ENTRY_ROLLBACK = :rollback
      ENTRY_CHANGE = :change
      ENTRY_SAVEPOINT = :savepoint
      ENTRY_CHECKPOINT = :checkpoint

      def initialize(log_path = nil)
        @log_path = log_path || "transaction.log"
        @log_file = nil
        @current_lsn = 0
        @checkpoint_lsn = 0
        @buffer = []
        @buffer_size = 1000
        @stats = {
          entries_written: 0,
          entries_read: 0,
          checkpoints: 0,
          buffer_flushes: 0,
          recovery_runs: 0
        }
        @lock = Mutex.new
        @flush_thread = nil
        
        create_log_directory
        open_log_file
        start_flush_thread
      end

      def log_start(transaction)
        write_entry({
          type: ENTRY_START,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          isolation_level: transaction.isolation_level,
          read_only: transaction.read_only
        })
      end

      def log_prepare(transaction)
        write_entry({
          type: ENTRY_PREPARE,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          changes: transaction.changes.size,
          modified_rows: transaction.modified_rows.size
        })
      end

      def log_commit(transaction)
        write_entry({
          type: ENTRY_COMMIT,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          commit_time: Time.now.iso8601
        })
      end

      def log_rollback(transaction)
        write_entry({
          type: ENTRY_ROLLBACK,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          rollback_time: Time.now.iso8601
        })
      end

      def log_change(transaction, change)
        write_entry({
          type: ENTRY_CHANGE,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          change: change
        })
      end

      def log_savepoint(transaction, savepoint)
        write_entry({
          type: ENTRY_SAVEPOINT,
          transaction_id: transaction.id,
          timestamp: Time.now.iso8601,
          savepoint: savepoint.name,
          position: savepoint.position
        })
      end

      def log_checkpoint
        @lock.synchronize do
          @checkpoint_lsn = @current_lsn
          write_entry({
            type: ENTRY_CHECKPOINT,
            timestamp: Time.now.iso8601,
            lsn: @checkpoint_lsn,
            active_transactions: active_transactions
          })
          @stats[:checkpoints] += 1
          flush_buffer
        end
      end

      def recover
        @lock.synchronize do
          @stats[:recovery_runs] += 1
          
          entries = []
          redo_entries = []
          undo_entries = []
          
          # Read all entries from log
          File.open(@log_path, "r") do |file|
            file.each_line do |line|
              entry = JSON.parse(line, symbolize_names: true)
              entries << entry
              
              case entry[:type]
              when ENTRY_PREPARE, ENTRY_COMMIT
                redo_entries << entry
              when ENTRY_START
                # Track active transactions
              end
            end
          end
          
          # Find last checkpoint
          checkpoint = entries.reverse.find { |e| e[:type] == ENTRY_CHECKPOINT }
          
          # REDO: Apply committed transactions
          committed = Set.new
          entries.each do |entry|
            if entry[:type] == ENTRY_COMMIT
              committed.add(entry[:transaction_id])
            end
          end
          
          redo_entries.each do |entry|
            if committed.include?(entry[:transaction_id])
              # REDO the changes
            end
          end
          
          # UNDO: Rollback uncommitted transactions
          entries.each do |entry|
            if entry[:type] == ENTRY_START && !committed.include?(entry[:transaction_id])
              # UNDO the changes
            end
          end
          
          @stats[:entries_read] += entries.size
          
          { entries: entries, committed: committed, checkpoint: checkpoint }
        end
      end

      def flush
        @lock.synchronize do
          flush_buffer
          @log_file.flush if @log_file
        end
      end

      def close
        @lock.synchronize do
          flush
          @log_file.close if @log_file
          @flush_thread.kill if @flush_thread
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            current_lsn: @current_lsn,
            checkpoint_lsn: @checkpoint_lsn,
            buffer_size: @buffer.size
          })
        end
      end

      private

      def create_log_directory
        dir = File.dirname(@log_path)
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
      end

      def open_log_file
        @log_file = File.open(@log_path, "a+")
        @log_file.sync = false
      rescue SystemCallError => e
        raise StorageError, "Failed to open transaction log: #{e.message}"
      end

      def write_entry(entry)
        @lock.synchronize do
          @current_lsn += 1
          entry[:lsn] = @current_lsn
          
          @buffer << entry
          @stats[:entries_written] += 1
          
          if @buffer.size >= @buffer_size
            flush_buffer
          end
        end
      end

      def flush_buffer
        return if @buffer.empty?
        
        @lock.synchronize do
          @buffer.each do |entry|
            @log_file.puts(JSON.generate(entry))
          end
          @log_file.flush
          @buffer.clear
          @stats[:buffer_flushes] += 1
        end
      rescue SystemCallError => e
        raise StorageError, "Failed to flush transaction log: #{e.message}"
      end

      def active_transactions
        # Get active transaction IDs
        @transaction_manager ? @transaction_manager.active_transactions.keys : []
      end

      def start_flush_thread
        @flush_thread = Thread.new do
          loop do
            sleep(5)  # Flush every 5 seconds
            begin
              flush
            rescue => e
              # Log error but continue
            end
          end
        end
      end
    end
  end
end