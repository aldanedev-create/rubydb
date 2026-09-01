# frozen_string_literal: true

require "thread"
require "set"
require "time"

module RubyDB
  module Concurrency
    # Scheduler - Manages execution of concurrent tasks with priorities
    class Scheduler
      attr_reader :stats, :queue_size

      # Scheduling policies
      POLICY_FIFO = :fifo
      POLICY_PRIORITY = :priority
      POLICY_ROUND_ROBIN = :round_robin
      POLICY_FAIR = :fair

      def initialize(config = {})
        @policy = config[:policy] || POLICY_FIFO
        @max_threads = config[:max_threads] || (Etc.nprocessors * 2)
        @min_threads = config[:min_threads] || [2, Etc.nprocessors].min
        @queue_size = 0
        @thread_pool = []
        @task_queue = []
        @priority_queues = {}
        @stats = {
          tasks_submitted: 0,
          tasks_completed: 0,
          tasks_failed: 0,
          tasks_queued: 0,
          avg_wait_time_ms: 0,
          avg_execution_time_ms: 0,
          total_wait_time_ms: 0,
          total_execution_time_ms: 0
        }
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @running = false
        @shutdown = false
        @scheduler_thread = nil

        # Initialize priority queues
        [1, 2, 3, 4, 5].each do |priority|
          @priority_queues[priority] = []
        end

        start
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @shutdown = false

          # Start worker threads
          @min_threads.times do
            start_worker
          end

          # Start scheduler thread
          @scheduler_thread = Thread.new do
            schedule_loop
          end
        end
      end

      def stop(wait = true)
        @lock.synchronize do
          @shutdown = true
          @cond.broadcast

          if wait
            @scheduler_thread&.join
            @thread_pool.each(&:join)
          end
        end
      end

      def submit(task, priority: 3, timeout: nil)
        @lock.synchronize do
          raise "Scheduler is shutting down" if @shutdown

          entry = {
            task: task,
            priority: priority,
            submitted_at: Time.now,
            timeout: timeout,
            status: :queued
          }

          if priority.is_a?(Integer) && priority.between?(1, 5)
            @priority_queues[priority] << entry
          else
            @task_queue << entry
          end

          @queue_size += 1
          @stats[:tasks_submitted] += 1
          @stats[:tasks_queued] += 1
          @cond.signal

          entry
        end
      end

      def submit_block(priority: 3, timeout: nil, &block)
        submit(block, priority: priority, timeout: timeout)
      end

      def wait_for_task(task_entry, timeout: nil)
        start_time = Time.now
        deadline = timeout ? start_time + timeout : nil

        loop do
          @lock.synchronize do
            break if task_entry[:status] == :completed || task_entry[:status] == :failed

            if deadline && Time.now > deadline
              task_entry[:status] = :timeout
              break
            end

            @cond.wait(@lock, 0.1)
          end
        end

        task_entry[:result]
      end

      def running?
        @running
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            queue_size: @queue_size,
            threads: @thread_pool.size,
            running: @running,
            policy: @policy,
            max_threads: @max_threads,
            min_threads: @min_threads
          })
        end
      end

      private

      def start_worker
        worker = Thread.new do
          worker_loop
        end
        @thread_pool << worker
        worker
      end

      def worker_loop
        while !@shutdown
          task_entry = nil

          @lock.synchronize do
            while !@shutdown && !has_task?
              @cond.wait(@lock, 1)
            end

            task_entry = dequeue_task
          end

          if task_entry
            execute_task(task_entry)
          end
        end
      end

      def schedule_loop
        while !@shutdown
          sleep(1) if @thread_pool.size >= @max_threads

          @lock.synchronize do
            # Adjust thread pool size based on workload
            if @queue_size > @thread_pool.size * 2 && @thread_pool.size < @max_threads
              start_worker
            elsif @queue_size < @thread_pool.size / 2 && @thread_pool.size > @min_threads
              # Could shrink pool
            end
          end
        end
      end

      def has_task?
        @task_queue.any? || @priority_queues.any? { |_, q| q.any? }
      end

      def dequeue_task
        # Priority-based dequeuing
        @priority_queues.keys.sort.each do |priority|
          queue = @priority_queues[priority]
          if queue.any?
            entry = queue.shift
            @queue_size -= 1
            return entry
          end
        end

        if @task_queue.any?
          entry = case @policy
          when POLICY_FIFO
            @task_queue.shift
          when POLICY_ROUND_ROBIN
            @task_queue.rotate!.first
          else
            @task_queue.shift
          end
          @queue_size -= 1
          return entry
        end

        nil
      end

      def execute_task(task_entry)
        start_time = Time.now
        task_entry[:status] = :running

        begin
          result = if task_entry[:task].is_a?(Proc)
            task_entry[:task].call
          else
            task_entry[:task]
          end

          task_entry[:status] = :completed
          task_entry[:result] = result
          @stats[:tasks_completed] += 1
        rescue => e
          task_entry[:status] = :failed
          task_entry[:error] = e
          @stats[:tasks_failed] += 1
        ensure
          execution_time = (Time.now - start_time) * 1000
          @stats[:total_execution_time_ms] += execution_time
          @stats[:avg_execution_time_ms] = @stats[:total_execution_time_ms] / @stats[:tasks_completed] if @stats[:tasks_completed] > 0
        end
      end
    end
  end
end