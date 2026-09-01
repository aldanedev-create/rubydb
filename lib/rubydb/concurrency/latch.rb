# frozen_string_literal: true

module RubyDB
  module Concurrency
    # Latch - A synchronization primitive that allows threads to wait until a count reaches zero
    class Latch
      attr_reader :count, :stats

      def initialize(count = 1)
        @count = count
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @stats = {
          wait_count: 0,
          signal_count: 0,
          timed_out: 0
        }
      end

      def await(timeout = nil)
        @mutex.synchronize do
          @stats[:wait_count] += 1

          if timeout
            deadline = Time.now + timeout
            while @count > 0 && Time.now < deadline
              @cond.wait(@mutex, [deadline - Time.now, 0.1].max)
            end

            if @count > 0
              @stats[:timed_out] += 1
              return false
            end
          else
            while @count > 0
              @cond.wait(@mutex)
            end
          end

          true
        end
      end

      def count_down(count = 1)
        @mutex.synchronize do
          @count -= count
          @count = 0 if @count < 0
          @stats[:signal_count] += count
          @cond.broadcast if @count == 0
        end
      end

      def count_up(count = 1)
        @mutex.synchronize do
          @count += count
        end
      end

      def reset(count = nil)
        @mutex.synchronize do
          @count = count || @count
          @cond.broadcast if @count == 0
        end
      end

      def ready?
        @mutex.synchronize { @count == 0 }
      end

      def wait(timeout = nil)
        await(timeout)
      end

      def to_s
        "Latch(count=#{@count})"
      end

      def inspect
        to_s
      end
    end

    # CountDownLatch - A latch that counts down from a specific number
    class CountDownLatch < Latch
      attr_reader :initial_count

      def initialize(count)
        super(count)
        @initial_count = count
      end

      def reset
        super(@initial_count)
      end

      def to_s
        "CountDownLatch(count=#{@count}/#{@initial_count})"
      end
    end
  end
end