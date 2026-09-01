# frozen_string_literal: true

module RubyDB
  module Concurrency
    # Mutex - A mutual exclusion lock with additional features
    class Mutex
      attr_reader :name, :stats, :owner

      def initialize(name = nil)
        @mutex = ::Mutex.new
        @name = name
        @owner = nil
        @lock_count = 0
        @waiters = []
        @stats = {
          lock_attempts: 0,
          lock_successes: 0,
          lock_failures: 0,
          unlock_count: 0,
          contention_count: 0,
          avg_wait_time_ms: 0,
          total_wait_time_ms: 0
        }
        @lock = Mutex.new
      end

      def synchronize
        lock
        begin
          yield
        ensure
          unlock
        end
      end

      def lock(timeout = nil)
        @lock.synchronize do
          @stats[:lock_attempts] += 1

          start_time = Time.now
          current_thread = Thread.current

          # If already locked by this thread, increment lock count
          if @owner == current_thread
            @lock_count += 1
            @stats[:lock_successes] += 1
            return true
          end

          # Try to acquire lock
          success = if timeout
            acquired = false
            deadline = Time.now + timeout
            while !acquired && Time.now < deadline
              acquired = @mutex.try_lock
              sleep(0.001) if !acquired
            end
            acquired
          else
            @mutex.lock
            true
          end

          if success
            @owner = current_thread
            @lock_count = 1
            @stats[:lock_successes] += 1

            wait_time = (Time.now - start_time) * 1000
            @stats[:total_wait_time_ms] += wait_time
            @stats[:avg_wait_time_ms] = @stats[:total_wait_time_ms] / @stats[:lock_successes]
          else
            @stats[:lock_failures] += 1
            false
          end
        end
      end

      def unlock
        @lock.synchronize do
          if @owner != Thread.current
            raise ThreadError, "Mutex not owned by current thread"
          end

          @lock_count -= 1

          if @lock_count == 0
            @owner = nil
            @mutex.unlock
            @stats[:unlock_count] += 1
          end

          true
        end
      end

      def locked?
        @mutex.locked?
      end

      def try_lock
        @lock.synchronize do
          @stats[:lock_attempts] += 1

          if @mutex.try_lock
            @owner = Thread.current
            @lock_count = 1
            @stats[:lock_successes] += 1
            true
          else
            @stats[:lock_failures] += 1
            @stats[:contention_count] += 1
            false
          end
        end
      end

      def owned?
        @owner == Thread.current
      end

      def to_s
        status = locked? ? "locked" : "unlocked"
        "#{@name || 'Mutex'} (#{status}, owner=#{@owner&.object_id})"
      end

      def inspect
        to_s
      end
    end

    # ReentrantMutex - A mutex that can be locked multiple times by the same thread
    class ReentrantMutex < Mutex
      def initialize(name = nil)
        super(name)
        @recursion_depth = 0
      end

      def lock(timeout = nil)
        @lock.synchronize do
          @stats[:lock_attempts] += 1

          if @owner == Thread.current
            @lock_count += 1
            @recursion_depth += 1
            @stats[:lock_successes] += 1
            return true
          end

          super
        end
      end

      def unlock
        @lock.synchronize do
          if @owner != Thread.current
            raise ThreadError, "Mutex not owned by current thread"
          end

          @lock_count -= 1
          @recursion_depth -= 1

          if @lock_count == 0
            @owner = nil
            @mutex.unlock
            @stats[:unlock_count] += 1
          end

          true
        end
      end

      def recursion_depth
        @recursion_depth
      end

      def to_s
        status = locked? ? "locked" : "unlocked"
        "#{@name || 'ReentrantMutex'} (#{status}, recursion=#{@recursion_depth})"
      end
    end
  end
end