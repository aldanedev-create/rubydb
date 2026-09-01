# frozen_string_literal: true

module RubyDB
  module Server
    # WorkerPool - Manages worker threads
    class WorkerPool
      attr_reader :stats

      def initialize(config, engine, transaction_manager)
        @config = config
        @engine = engine
        @transaction_manager = transaction_manager
        @min_workers = config[:min_workers] || 2
        @max_workers = config[:max_workers] || 20
        @workers = []
        @worker_counter = 0
        @stats = {
          total_workers: 0,
          active_workers: 0,
          idle_workers: 0,
          workers_created: 0,
          workers_destroyed: 0,
          total_requests: 0,
          queue_size: 0
        }
        @lock = Mutex.new
        @running = false
        @queue = Queue.new
        @cleanup_thread = nil
        @scaling_thread = nil
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true

          # Create initial workers
          @min_workers.times { create_worker }

          # Start scaling thread
          @scaling_thread = Thread.new { scaling_loop }

          # Start cleanup thread
          @cleanup_thread = Thread.new { cleanup_loop }

          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          # Stop scaling thread
          if @scaling_thread
            @scaling_thread.kill
            @scaling_thread = nil
          end

          # Stop cleanup thread
          if @cleanup_thread
            @cleanup_thread.kill
            @cleanup_thread = nil
          end

          # Stop all workers
          @workers.each(&:stop)
          @workers.clear

          true
        end
      end

      def submit(request)
        @lock.synchronize do
          return false unless @running

          @queue << request
          @stats[:total_requests] += 1
          @stats[:queue_size] = @queue.size

          # Find idle worker
          worker = find_idle_worker

          if worker
            worker.submit(request)
          else
            # Queue the request
            @queue << request
          end

          true
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            workers: @workers.size,
            running: @running,
            min_workers: @min_workers,
            max_workers: @max_workers,
            queue_size: @queue.size
          })
        end
      end

      private

      def create_worker
        @worker_counter += 1
        worker = Worker.new(@worker_counter, @config, @engine, @transaction_manager)
        worker.start
        @workers << worker
        @stats[:workers_created] += 1
        @stats[:total_workers] = @workers.size
        worker
      end

      def destroy_worker(worker)
        worker.stop
        @workers.delete(worker)
        @stats[:workers_destroyed] += 1
        @stats[:total_workers] = @workers.size
      end

      def find_idle_worker
        @workers.find { |w| !w.busy? }
      end

      def scaling_loop
        while @running
          sleep(5)

          @lock.synchronize do
            # Scale up if queue is growing
            if @queue.size > @workers.size * 2 && @workers.size < @max_workers
              create_worker
            end

            # Scale down if queue is empty and we have extra workers
            if @queue.empty? && @workers.size > @min_workers
              idle_workers = @workers.select { |w| !w.busy? }
              if idle_workers.size > 1
                destroy_worker(idle_workers.first)
              end
            end
          end
        end
      end

      def cleanup_loop
        while @running
          sleep(60)

          @lock.synchronize do
            # Remove dead workers
            @workers.reject! { |w| !w.running? }
          end
        end
      end
    end
  end
end