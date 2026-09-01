# frozen_string_literal: true

module RubyDB
  module Concurrency
    # RWLock - Read-Write lock with fairness
    class RWLock
      attr_reader :stats

      def initialize(config = {})
        @mutex = Mutex.new
        @readers = 0
        @writers = 0
        @pending_readers = 0
        @pending_writers = 0
        @prefer_writer = config[:prefer_writer] || false
        @fair = config[:fair] || true
        @stats = {
          read_locks: 0,
          write_locks: 0,
          read_unlocks: 0,
          write_unlocks: 0,
          read_waits: 0,
          write_waits: 0,
          contention: 0
        }
        @cond = ConditionVariable.new
        @lock = Mutex.new
      end

      def read_lock(timeout = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:read_locks] += 1

          # Wait if there are writers or pending writers
          while (@writers > 0 || (@prefer_writer && @pending_writers > 0)) ||
                (@fair && @pending_writers > 0 && @pending_readers > @pending_writers)
            @stats[:read_waits] += 1
            @stats[:contention] += 1
            
            if timeout
              deadline = Time.now + timeout
              @cond.wait(@lock, [deadline - Time.now, 0.1].max)
              if Time.now >= deadline && (@writers > 0 || @pending_writers > 0)
                return false
              end
            else
              @cond.wait(@lock)
            end
          end

          @readers += 1
          @stats[:read_waits] += 1 if Time.now - start_time > 0.01
          true
        end
      end

      def write_lock(timeout = nil)
        @lock.synchronize do
          start_time = Time.now
          @stats[:write_locks] += 1
          @pending_writers += 1

          # Wait until no readers or writers
          while @readers > 0 || @writers > 0 || @pending_readers > 0
            @stats[:write_waits] += 1
            @stats[:contention] += 1

            if timeout
              deadline = Time.now + timeout
              @cond.wait(@lock, [deadline - Time.now, 0.1].max)
              if Time.now >= deadline && (@readers > 0 || @writers > 0)
                @pending_writers -= 1
                return false
              end
            else
              @cond.wait(@lock)
            end
          end

          @pending_writers -= 1
          @writers += 1
          true
        end
      end

      def read_unlock
        @lock.synchronize do
          if @readers <= 0
            raise "No readers to unlock"
          end

          @readers -= 1
          @stats[:read_unlocks] += 1
          @cond.broadcast if @readers == 0
          true
        end
      end

      def write_unlock
        @lock.synchronize do
          if @writers <= 0
            raise "No writers to unlock"
          end

          @writers -= 1
          @stats[:write_unlocks] += 1
          @cond.broadcast
          true
        end
      end

      def with_read_lock
        if read_lock
          begin
            yield
          ensure
            read_unlock
          end
        end
      end

      def with_write_lock
        if write_lock
          begin
            yield
          ensure
            write_unlock
          end
        end
      end

      def try_read_lock
        @lock.synchronize do
          if @writers == 0 && !(@prefer_writer && @pending_writers > 0)
            @readers += 1
            @stats[:read_locks] += 1
            true
          else
            @stats[:contention] += 1
            false
          end
        end
      end

      def try_write_lock
        @lock.synchronize do
          if @readers == 0 && @writers == 0
            @writers += 1
            @stats[:write_locks] += 1
            true
          else
            @stats[:contention] += 1
            false
          end
        end
      end

      def reader_count
        @readers
      end

      def writer_count
        @writers
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            readers: @readers,
            writers: @writers,
            pending_readers: @pending_readers,
            pending_writers: @pending_writers,
            total_locks: @stats[:read_locks] + @stats[:write_locks]
          })
        end
      end
    end
  end
end