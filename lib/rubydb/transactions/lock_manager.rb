# frozen_string_literal: true

module RubyDB
  module Transactions

    # Import lock and transaction classes
require_relative "lock"
require_relative "transaction"

    # LockManager - Manages locks for transactions
    class LockManager
      attr_reader :locks, :waiting, :stats

      def initialize(config = {})
        @locks = {}
        @waiting = {}
        @lock_timeout = config[:lock_timeout] || 30
        @deadlock_detection = config[:deadlock_detection] != false
        @stats = {
          locks_acquired: 0,
          locks_released: 0,
          lock_waits: 0,
          lock_timeouts: 0,
          deadlocks_detected: 0
        }
        @lock = Mutex.new
      end

      def acquire_lock(transaction, table_name, row_id, lock_type, timeout = @lock_timeout)
        @lock.synchronize do
          key = lock_key(table_name, row_id)
          
          # Check if transaction already has lock
          if has_lock?(transaction, key)
            return upgrade_lock(transaction, key, lock_type)
          end
          
          # Check if lock is available
          current_lock = @locks[key]
          
          if current_lock.nil?
            # No lock exists - acquire
            @locks[key] = Lock.new(key, lock_type, transaction)
            @stats[:locks_acquired] += 1
            return true
          end
          
          # Check compatibility
          if compatible?(current_lock, lock_type, transaction)
            # Add transaction to lock
            current_lock.add_holder(transaction, lock_type)
            @stats[:locks_acquired] += 1
            return true
          end
          
          # Lock conflict - wait
          @stats[:lock_waits] += 1
          result = wait_for_lock(transaction, key, lock_type, timeout)
          
          # Check for deadlock
          if @deadlock_detection && !result
            detect_deadlock
          end
          
          result
        end
      end

      def release_locks(transaction)
        @lock.synchronize do
          @locks.each do |key, lock|
            if lock.holders.key?(transaction.id)
              lock.remove_holder(transaction)
              @stats[:locks_released] += 1
              
              # Remove empty lock
              if lock.holders.empty?
                @locks.delete(key)
                
                # Wake up waiting transactions
                wake_waiting_transactions(key)
              end
            end
          end
        end
      end

      def release_all_locks
        @lock.synchronize do
          @locks.clear
          @waiting.clear
          @stats[:locks_released] += 1
        end
      end

      def has_lock?(transaction, key)
        lock = @locks[key]
        return false unless lock
        lock.holders.key?(transaction.id)
      end

      def lock_type(transaction, key)
        lock = @locks[key]
        return nil unless lock
        lock.holders[transaction.id] if lock.holders.key?(transaction.id)
      end

      def waiting_transactions
        @waiting.size
      end

      def total_locks
        @locks.size
      end

      def lock_info
        @locks.transform_values do |lock|
          {
            type: lock.type,
            holders: lock.holders.keys,
            waiters: lock.waiters.keys
          }
        end
      end

      private

      def lock_key(table_name, row_id)
        "#{table_name}:#{row_id}"
      end

      def compatible?(lock, lock_type, transaction)
        # Check if any holder has incompatible lock
        lock.holders.each do |holder_id, holder_type|
          next if holder_id == transaction.id
          
          if !compatible_lock_types(holder_type, lock_type)
            return false
          end
        end
        
        true
      end

      def compatible_lock_types(type1, type2)
        return true if type1 == type2
        
        # Shared locks are compatible with shared locks
        if type1 == :shared && type2 == :shared
          return true
        end
        
        # Exclusive locks are incompatible with any other
        if type1 == :exclusive || type2 == :exclusive
          return false
        end
        
        true
      end

      def upgrade_lock(transaction, key, new_type)
        lock = @locks[key]
        current_type = lock.holders[transaction.id]
        
        # Check if upgrade is needed
        return true if current_type == new_type
        
        # Check if upgrade is possible
        if new_type == :exclusive && current_type == :shared
          # Need to check if other transactions hold shared locks
          if lock.holders.size == 1 && lock.holders.key?(transaction.id)
            # Only this transaction holds the lock - upgrade
            lock.holders[transaction.id] = :exclusive
            @stats[:locks_acquired] += 1
            return true
          end
        end
        
        false
      end

      def wait_for_lock(transaction, key, lock_type, timeout)
        start_time = Time.now
        
        # Add to waiters
        @waiting[transaction.id] ||= {}
        @waiting[transaction.id][key] = {
          lock_type: lock_type,
          start_time: start_time
        }
        
        # Wait loop
        while Time.now - start_time < timeout
          # Check if lock is available
          if compatible?(@locks[key], lock_type, transaction)
            # Remove from waiting
            @waiting[transaction.id].delete(key)
            
            # Acquire lock
            @locks[key].add_holder(transaction, lock_type)
            @stats[:locks_acquired] += 1
            return true
          end
          
          sleep(0.01)  # Small sleep to avoid busy waiting
        end
        
        # Timeout
        @stats[:lock_timeouts] += 1
        @waiting[transaction.id].delete(key)
        false
      end

      def wake_waiting_transactions(key)
        # Find waiting transactions for this key
        @waiting.each do |txn_id, waits|
          if waits.key?(key)
            # Transaction is waiting - it will be woken in wait loop
          end
        end
      end

      def detect_deadlock
        # Build wait-for graph
        graph = {}
        
        @waiting.each do |txn_id, waits|
          graph[txn_id] = Set.new
          waits.each do |key, _|
            @locks[key]&.holders&.each do |holder_id, _|
              graph[txn_id] << holder_id
            end
          end
        end
        
        # Detect cycles
        cycles = detect_cycles(graph)
        
        if cycles.any?
          @stats[:deadlocks_detected] += 1
          # Resolve by aborting the transaction with lowest priority
          # (Simplified - in production would use more sophisticated algorithm)
          cycles.each do |cycle|
            victim = cycle.min_by { |id| @waiting[id]&.size || 0 }
            abort_transaction(victim) if victim
          end
        end
      end

      def detect_cycles(graph)
        cycles = []
        visited = Set.new
        recursion_stack = Set.new
        
        graph.each do |node, _|
          if !visited.include?(node) && detect_cycle_dfs(node, graph, visited, recursion_stack)
            cycles << [node]
          end
        end
        
        cycles
      end

      def detect_cycle_dfs(node, graph, visited, recursion_stack)
        return false if visited.include?(node)
        
        visited.add(node)
        recursion_stack.add(node)
        
        graph[node]&.each do |neighbor|
          if recursion_stack.include?(neighbor) ||
             detect_cycle_dfs(neighbor, graph, visited, recursion_stack)
            return true
          end
        end
        
        recursion_stack.delete(node)
        false
      end

      def abort_transaction(transaction_id)
        # Find and abort the transaction
        # In production, this would use the transaction manager
        @waiting.delete(transaction_id)
        release_locks(Transaction.new(id: transaction_id))
      end
    end
  end
end