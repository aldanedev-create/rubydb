# frozen_string_literal: true

require "concurrent"

# Import all transaction components
require_relative "transaction"
require_relative "transaction_id"
require_relative "lock_manager"
require_relative "commit_manager"
require_relative "transaction_log"
require_relative "isolation"
require_relative "savepoint"

# Import engine for rollback operations
require_relative "../storage/engine"

module RubyDB
  module Transactions
    # TransactionManager - Manages all database transactions
    class TransactionManager
      attr_reader :active_transactions, :committed_transactions, :aborted_transactions
      attr_reader :lock_manager, :commit_manager, :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @active_transactions = {}
        @committed_transactions = []
        @aborted_transactions = []
        @transaction_log = TransactionLog.new(config[:log_path])
        @lock_manager = LockManager.new(config.merge(transaction_manager: self))
        @commit_manager = CommitManager.new(self, config)
        @stats = {
          transactions_started: 0,
          transactions_committed: 0,
          transactions_aborted: 0,
          transactions_prepared: 0,
          transactions_in_doubt: 0,
          deadlocks_detected: 0,
          deadlocks_resolved: 0,
          lock_timeouts: 0,
          total_commit_time_ms: 0,
          total_rollback_time_ms: 0
        }
        @next_txn_id = 1
        @lock = Mutex.new
        @cleanup_thread = nil

        # Start cleanup thread
        start_cleanup_thread if config[:auto_cleanup] != false

        # Recover transactions on startup
        recover if config[:recovery] != false
      end

      def begin_transaction(options = {})
        @lock.synchronize do
          txn = Transaction.new({
            id: generate_id,
            isolation_level: options[:isolation_level] || :read_committed,
            read_only: options[:read_only] || false,
            timeout: options[:timeout] || 30,
            priority: options[:priority] || 0,
            name: options[:name]
          })

          @active_transactions[txn.id] = txn
          @stats[:transactions_started] += 1

          # Log transaction start
          @transaction_log.log_start(txn)

          txn
        end
      end

      def commit_transaction(transaction)
        @lock.synchronize do
          return false unless transaction&.active?

          start_time = Time.now

          # Check for conflicts
          if detect_conflicts(transaction)
            @stats[:deadlocks_detected] += 1
            return false
          end

          # Prepare transaction
          transaction.prepare
          @stats[:transactions_prepared] += 1

          # Log prepare
          @transaction_log.log_prepare(transaction)

          # Commit
          @commit_manager.commit(transaction)

          # Update stats
          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:transactions_committed] += 1
          @stats[:total_commit_time_ms] += elapsed_ms

          # Log commit
          @transaction_log.log_commit(transaction)

          # Move to committed
          @active_transactions.delete(transaction.id)
          @committed_transactions << transaction

          # Clean old committed transactions
          cleanup_committed_transactions if @committed_transactions.size > 1000

          true
        end
      end

      def rollback_transaction(transaction)
        @lock.synchronize do
          return false unless transaction&.active?

          start_time = Time.now

          # Rollback changes
          rollback_changes(transaction)

          # Abort transaction
          transaction.abort
          @stats[:transactions_aborted] += 1

          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          @stats[:total_rollback_time_ms] += elapsed_ms

          # Log rollback
          @transaction_log.log_rollback(transaction)

          # Move to aborted
          @active_transactions.delete(transaction.id)
          @aborted_transactions << transaction

          # Clean old aborted transactions
          cleanup_aborted_transactions if @aborted_transactions.size > 1000

          true
        end
      end

      def get_transaction(id)
        @lock.synchronize do
          @active_transactions[id] ||
            @committed_transactions.find { |t| t.id == id } ||
            @aborted_transactions.find { |t| t.id == id }
        end
      end

      def active_transaction_count
        @active_transactions.size
      end

      def find_latest_transaction
        @lock.synchronize do
          all = @committed_transactions + @aborted_transactions
          all.max_by { |t| t.start_time }
        end
      end

      def detect_deadlock
        cycles = detect_cycles(build_wait_for_graph)
        return false if cycles.empty?

        @lock.synchronize { @stats[:deadlocks_detected] += cycles.size }
        cycles.each { |cycle| resolve_deadlock(cycle) }
        true
      end

      def resolve_deadlock(cycle)
        transactions = Array(cycle).filter_map do |entry|
          if entry.respond_to?(:priority)
            entry
          else
            @lock.synchronize { @active_transactions[entry] }
          end
        end
        victim = @lock.synchronize do
          transactions.min_by { |transaction| transaction.priority.to_i }
        end
        return nil unless victim

        rollback_transaction(victim)
        @lock.synchronize { @stats[:deadlocks_resolved] += 1 }
        victim
      end

      def acquire_lock(transaction, table_name, row_id, lock_type)
        valid = @lock.synchronize do
          return false unless transaction.active?

          # Check for timeout
          if transaction.expired?
            @stats[:lock_timeouts] += 1
            return false
          end
          true
        end
        return false unless valid

        # Do not hold the transaction-manager mutex while a lock wait blocks;
        # deadlock resolution must be able to return through this method.
        result = @lock_manager.acquire_lock(
          transaction,
          table_name,
          row_id,
          lock_type,
          transaction.timeout
        )

        if result
          transaction.add_locked_row(table_name, row_id, lock_type)
        elsif @lock_manager.deadlock_victim?(transaction.id)
          @lock.synchronize do
            @stats[:deadlocks_detected] += 1
          end
          rollback_transaction(transaction)
          @lock_manager.clear_deadlock_victim(transaction.id)
        end

        result
      end

      def release_locks(transaction)
        @lock.synchronize do
          @lock_manager.release_locks(transaction)
          transaction.locked_rows.clear
          true
        end
      end

      def release_all_locks
        @lock.synchronize do
          @lock_manager.release_all_locks
          @active_transactions.each do |_, txn|
            txn.locked_rows.clear
          end
          true
        end
      end

      def recover
        @lock.synchronize do
          # Recover from transaction log
          recovery = @transaction_log.recover
          entries = recovery[:entries] || []

          entries.each do |entry|
            case entry[:type]
            when :prepare
              # Transaction was prepared but not committed
              txn = get_transaction(entry[:transaction_id])
              if txn&.prepared?
                # Commit if we can
                if can_commit?(txn)
                  commit_transaction(txn)
                else
                  txn.mark_in_doubt
                  @stats[:transactions_in_doubt] += 1
                end
              end
            when :commit
              # Already committed
            when :rollback
              # Already rolled back
            end
          end
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            active_count: @active_transactions.size,
            committed_count: @committed_transactions.size,
            aborted_count: @aborted_transactions.size,
            in_doubt_count: @active_transactions.count { |_, t| t.in_doubt? },
            avg_commit_time: average_commit_time,
            avg_rollback_time: average_rollback_time,
            locks_held: @lock_manager.total_locks,
            lock_waiting: @lock_manager.waiting_transactions
          })
        end
      end

      private

      def generate_id
        "txn_#{Time.now.to_i}_#{@next_txn_id}"
      ensure
        @next_txn_id += 1
      end

      def rollback_changes(transaction)
        # Rollback in reverse order
        transaction.modified_rows.each do |row_id, info|
          @engine.update_row(info[:table], row_id, info[:old])
        end
        transaction.changes.reverse.each do |change|
          undo_change(change)
        end
      end

      def undo_change(change)
        case change[:type]
        when :insert
          # Delete inserted row
          @engine.delete_row(change[:table], change[:row_id])
        when :update
          # Restore old values
          @engine.update_row(change[:table], change[:row_id], change[:old_values])
        when :delete
          # Reinsert deleted row
          @engine.insert_row(change[:table], change[:columns], change[:row_data])
        end
      end

      def detect_conflicts(transaction)
        # Check for write-write conflicts
        transaction.modified_rows.each do |row_id, info|
          @active_transactions.each do |_, other_txn|
            next if other_txn.id == transaction.id

            if other_txn.modified_rows.key?(row_id)
              return true
            end
          end
        end

        false
      end

      def build_wait_for_graph
        @lock_manager.wait_for_graph
      end

      def detect_cycles(graph)
        cycles = []
        visited = Set.new
        active = Set.new
        path = []

        graph.each_key do |node|
          detect_cycle_dfs(node, graph, visited, active, path, cycles) unless visited.include?(node)
        end
        cycles
      end

      def detect_cycle_dfs(node, graph, visited, active, path, cycles)
        if active.include?(node)
          start = path.index(node)
          cycle = path[start..] + [node]
          cycles << cycle unless cycles.include?(cycle)
          return
        end
        return if visited.include?(node)

        visited.add(node)
        active.add(node)
        path << node

        graph[node]&.each { |neighbor| detect_cycle_dfs(neighbor, graph, visited, active, path, cycles) }

        path.pop
        active.delete(node)
      end

      def can_commit?(transaction)
        # Check if all prerequisites are met
        transaction.modified_rows.each do |_, info|
          # Check if no other active transaction modified the same row
          @active_transactions.each do |_, other|
            next if other.id == transaction.id
            if other.modified_rows.key?(info[:row_id])
              return false
            end
          end
        end

        true
      end

      def cleanup_committed_transactions
        if @committed_transactions.size > 1000
          @committed_transactions = @committed_transactions.last(100)
        end
      end

      def cleanup_aborted_transactions
        if @aborted_transactions.size > 1000
          @aborted_transactions = @aborted_transactions.last(100)
        end
      end

      def average_commit_time
        return 0 if @stats[:transactions_committed] == 0
        @stats[:total_commit_time_ms] / @stats[:transactions_committed]
      end

      def average_rollback_time
        return 0 if @stats[:transactions_aborted] == 0
        @stats[:total_rollback_time_ms] / @stats[:transactions_aborted]
      end

      def start_cleanup_thread
        @cleanup_thread = Thread.new do
          loop do
            sleep(60)  # Run every minute

            begin
              # Cleanup expired transactions
              @active_transactions.each do |id, txn|
                if txn.expired?
                  rollback_transaction(txn)
                end
              end

              # Detect deadlocks
              detect_deadlock
            rescue
              # Log error but continue
            end
          end
        end
      end
    end
  end
end
