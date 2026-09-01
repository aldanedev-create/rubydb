# frozen_string_literal: true

require "set"

module RubyDB
  module Concurrency
    # DeadlockDetector - Detects and resolves deadlocks
    class DeadlockDetector
      attr_reader :stats

      def initialize(config = {})
        @lock_graph = LockGraph.new
        @deadlock_resolution = config[:resolution] || :abort_victim
        @timeout = config[:timeout] || 30
        @max_attempts = config[:max_attempts] || 3
        @stats = {
          deadlocks_detected: 0,
          deadlocks_resolved: 0,
          victims_aborted: 0,
          detection_runs: 0,
          avg_detection_time_ms: 0,
          total_detection_time_ms: 0
        }
        @lock = Mutex.new
        @detection_thread = nil
        @running = false
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @detection_thread = Thread.new do
            detection_loop
          end
        end
      end

      def stop
        @lock.synchronize do
          @running = false
          @detection_thread&.kill
          @detection_thread = nil
        end
      end

      def detect_deadlocks
        @lock.synchronize do
          @stats[:detection_runs] += 1
          start_time = Time.now

          # Build wait-for graph
          @lock_graph.build

          # Detect cycles
          cycles = @lock_graph.detect_cycles

          if cycles.any?
            @stats[:deadlocks_detected] += cycles.size
            cycles.each do |cycle|
              resolve_deadlock(cycle)
            end
          end

          detection_time = (Time.now - start_time) * 1000
          @stats[:total_detection_time_ms] += detection_time
          @stats[:avg_detection_time_ms] = @stats[:total_detection_time_ms] / @stats[:detection_runs]

          cycles
        end
      end

      def resolve_deadlock(cycle)
        # Choose victim based on policy
        victim = choose_victim(cycle)

        if victim
          abort_victim(victim)
          @stats[:deadlocks_resolved] += 1
          @stats[:victims_aborted] += 1
        end

        victim
      end

      def choose_victim(cycle)
        # Choose the transaction with lowest priority or oldest timestamp
        # For simplicity, choose the one with the most locks
        cycle.max_by { |txn| txn[:locks] || 0 }
      end

      def abort_victim(victim)
        # Abort the victim transaction
        # In production, this would call the transaction manager
        victim[:aborted] = true
        victim[:abort_time] = Time.now

        # Release all locks held by victim
        @lock_graph.release_locks(victim[:id])
      end

      def add_lock_holder(resource, holder)
        @lock.synchronize do
          @lock_graph.add_holder(resource, holder)
        end
      end

      def add_lock_waiter(resource, waiter)
        @lock.synchronize do
          @lock_graph.add_waiter(resource, waiter)
        end
      end

      def remove_transaction(transaction_id)
        @lock.synchronize do
          @lock_graph.remove_transaction(transaction_id)
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            running: @running,
            graph_size: @lock_graph.size,
            graph_edges: @lock_graph.edge_count
          })
        end
      end

      private

      def detection_loop
        while @running
          sleep(@timeout)
          begin
            detect_deadlocks
          rescue => e
            # Log error but continue
          end
        end
      end
    end
  end
end