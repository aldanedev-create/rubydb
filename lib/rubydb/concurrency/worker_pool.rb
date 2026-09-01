# frozen_string_literal: true

module RubyDB
  module Concurrency
    # WorkerPool - Manages a pool of worker threads
    class WorkerPool
      attr_reader :stats, :size, :active_count, :idle_count

      def initialize(config = {})
        @size = config[:size] || Etc.nprocessors
        @max_size = config[:max_size] || @size * 2
        @min_size = config[:min_size] || [1, @size].min
        @workers = []
        @task_queue = Queue.new
        @stats = {
          tasks_processed: 0,
          tasks_failed: 0,
          tasks_queued: 0,
          avg_processing_time_ms: 0,
          total_processing_time_ms: 0,
          worker_creations: 0,
          worker_destructions: 0
        }
        @shutdown = false
        @lock = Mutex.new
        @cond = ConditionVariable.new
        @idle_count = 0
        @active_count = 0
        @worker_id_counter = 0

        # Pre-create workers
        @size.times { create_worker }
      end

      def submit(task)
        @task_queue << task
        @stats[:tasks_queued] += 1
        @cond.signal
        task
      end

      def submit_block(&block)
        submit(block)
      end

      def shutdown(wait = true)
        @lock.synchronize do
          @shutdown = true
          @cond.broadcast

          if wait
            @workers.each(&:join)
          end
        end
      end

      def resize(new_size)
        @lock.synchronize do
          new_size = [new_size, @min_size].max
          new_size = [new_size, @max_size].min

          if new_size > @workers.size
            (new_size - @workers.size).times { create_worker }
          elsif new_size < @workers.size
            (new_size - @workers.size).times do
              worker = @workers.pop
              worker&.kill
              @stats[:worker_destructions] += 1
            end
          end

          @size = new_size
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            size: @size,
            workers: @workers.size,
            active: @active_count,
            idle: @idle_count,
            queue_size: @task_queue.size,
            max_size: @max_size,
            min_size: @min_size,
            shutdown: @shutdown
          })
        end
      end

      private

      def create_worker
        @worker_id_counter += 1
        worker_id = @worker_id_counter

        worker = Thread.new do
          worker_loop(worker_id)
        end

        @workers << worker
        @stats[:worker_creations] += 1
        worker
      end

      def worker_loop(worker_id)
        while !@shutdown
          task = nil

          begin
            task = @task_queue.pop
            @lock.synchronize { @idle_count -= 1; @active_count += 1 }

            start_time = Time.now

            if task.is_a?(Proc)
              task.call
            elsif task.respond_to?(:call)
              task.call
            end

            processing_time = (Time.now - start_time) * 1000
            @lock.synchronize do
              @stats[:tasks_processed] += 1
              @stats[:total_processing_time_ms] += processing_time
              @stats[:avg_processing_time_ms] = @stats[:total_processing_time_ms] / @stats[:tasks_processed]
            end

          rescue => e
            @lock.synchronize do
              @stats[:tasks_failed] += 1
            end
          ensure
            @lock.synchronize do
              @active_count -= 1
              @idle_count += 1
            end
          end
        end
      end
    end
  end
end