# frozen_string_literal: true

require "set"

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
        @transaction_manager = config[:transaction_manager]
        @stats = {
          locks_acquired: 0,
          locks_released: 0,
          lock_waits: 0,
          lock_timeouts: 0,
          deadlocks_detected: 0,
          deadlocks_resolved: 0
        }
        @lock = Mutex.new
        @condition = ConditionVariable.new
        @transactions = {}
        @deadlock_victims = {}
      end

      def acquire_lock(transaction, table_name, row_id, lock_type, timeout = @lock_timeout)
        @lock.synchronize do
          @transactions[transaction.id] = transaction
          return false unless transaction.active?

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
                @condition.broadcast
              end
            end
          end
          @transactions.delete(transaction.id)
        end
      end

      def release_all_locks
        @lock.synchronize do
          @locks.clear
          @waiting.clear
          @transactions.clear
          @deadlock_victims.clear
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

      def deadlock_victim?(transaction_id)
        @lock.synchronize { @deadlock_victims.key?(transaction_id) }
      end

      def clear_deadlock_victim(transaction_id)
        @lock.synchronize { @deadlock_victims.delete(transaction_id) }
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

      # Return the current wait-for graph as transaction ids. This is a
      # snapshot intended for monitoring and transaction-manager deadlock
      # resolution; callers never receive mutable lock-manager state.
      def wait_for_graph
        @lock.synchronize { build_wait_for_graph }
      end

      private

      def build_wait_for_graph
        graph = {}
        @waiting.each do |transaction_id, waits|
          graph[transaction_id] = Set.new
          waits.each_key do |key|
            @locks[key]&.holders&.each_key do |holder_id|
              graph[holder_id] ||= Set.new
              graph[transaction_id] << holder_id
            end
          end
        end
        graph
      end

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
        while (remaining = timeout - (Time.now - start_time)) > 0
          if !transaction.active? || @deadlock_victims.key?(transaction.id)
            waits = @waiting[transaction.id]
            waits&.delete(key)
            @waiting.delete(transaction.id) if waits&.empty?
            return false
          end

          # Check if lock is available
          if @locks[key].nil? || compatible?(@locks[key], lock_type, transaction)
            # Remove from waiting
            @waiting[transaction.id].delete(key)
            @waiting.delete(transaction.id) if @waiting[transaction.id].empty?
            
            # Acquire lock
            @locks[key] ||= Lock.new(key, lock_type)
            @locks[key].add_holder(transaction, lock_type)
            @stats[:locks_acquired] += 1
            return true
          end

          # ConditionVariable releases @lock while waiting, allowing the
          # current holder to release its lock and wake this waiter.
          @condition.wait(@lock, remaining)
        end
        
        # Detect while the timed-out waiter is still in the wait graph. The
        # previous ordering removed it first, making a two-transaction cycle
        # impossible to observe. Resolution is performed by the unlocked
        # helper because this method already owns @lock.
        detect_deadlock if @deadlock_detection

        # Timeout or deadlock victim
        @stats[:lock_timeouts] += 1
        waits = @waiting[transaction.id]
        waits&.delete(key)
        @waiting.delete(transaction.id) if waits&.empty?
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
        graph = build_wait_for_graph

        # Detect cycles
        cycles = detect_cycles(graph)
        
        if cycles.any?
          @stats[:deadlocks_detected] += 1
          # Resolve by aborting the lowest-priority transaction. The victim is
          # marked before locks are released so its waiter cannot reacquire a
          # lock after the condition variable wakes it.
          cycles.each do |cycle|
            victim = cycle.compact.min_by { |id| [@transactions[id]&.priority.to_i, id.to_s] }
            abort_transaction_unlocked(victim) if victim
          end
        end
      end

      def detect_cycles(graph)
        cycles = []
        visited = Set.new
        active = Set.new
        path = []
        
        graph.keys.each do |node|
          detect_cycle_dfs(node, graph, visited, active, path, cycles) unless visited.include?(node)
        end
        
        cycles
      end

      def detect_cycle_dfs(node, graph, visited, active, path, cycles)
        if active.include?(node)
          start = path.index(node)
          cycle = path[start..] + [node]
          cycles << cycle unless cycles.any? { |existing| existing == cycle }
          return
        end
        return if visited.include?(node)
        
        visited.add(node)
        active.add(node)
        path << node
        
        graph[node]&.each do |neighbor|
          detect_cycle_dfs(neighbor, graph, visited, active, path, cycles)
        end
        
        path.pop
        active.delete(node)
      end

      def abort_transaction(transaction_id)
        transaction = if @transaction_manager.respond_to?(:get_transaction)
          @transaction_manager.get_transaction(transaction_id)
        end
        if transaction && @transaction_manager.respond_to?(:rollback_transaction)
          @transaction_manager.rollback_transaction(transaction)
        end
        @lock.synchronize { abort_transaction_unlocked(transaction_id) }
      end

      # Called only while @lock is held. It must never call back into the
      # transaction manager, whose own mutex may be held by the caller.
      def abort_transaction_unlocked(transaction_id)
        transaction = @transactions[transaction_id]
        if @transaction_manager
          @deadlock_victims[transaction_id] = transaction if transaction
        else
          transaction&.abort
        end

        @waiting.delete(transaction_id)
        @locks.each do |key, lock|
          next unless lock.holders.key?(transaction_id)

          lock.remove_holder(Transaction.new(id: transaction_id))
          @locks.delete(key) if lock.holders.empty?
        end
        @stats[:deadlocks_resolved] += 1
        @condition.broadcast
      end
    end
  end
end
