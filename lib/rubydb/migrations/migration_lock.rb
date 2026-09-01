# frozen_string_literal: true

require "time"

module RubyDB
  module Migrations
    # MigrationLock - Prevents concurrent migrations
    class MigrationLock
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @lock_table = config[:lock_table] || "migration_lock"
        @lock_timeout = config[:lock_timeout] || 300 # 5 minutes
        @lock_acquired = false
        @lock_id = nil
        @lock_holder = nil
        @lock_acquired_at = nil
        @stats = {
          locks_acquired: 0,
          locks_released: 0,
          locks_failed: 0,
          lock_contention: 0,
          lock_timeouts: 0
        }
        @lock = Mutex.new
      end

      def acquire_lock
        @lock.synchronize do
          return true if @lock_acquired

          @stats[:locks_acquired] += 1

          # Check if lock exists
          if lock_exists?
            owner, acquired_at = get_lock_info

            # Check if lock is stale
            if Time.now - acquired_at > @lock_timeout
              # Force release stale lock
              release_lock_force
              @stats[:lock_timeouts] += 1
            else
              @stats[:lock_contention] += 1
              @stats[:locks_failed] += 1
              return false
            end
          end

          # Acquire lock
          acquire_lock_force
          @lock_acquired = true
          @lock_acquired_at = Time.now
          @lock_id = generate_lock_id

          true
        end
      end

      def release_lock
        @lock.synchronize do
          return false unless @lock_acquired

          release_lock_force
          @lock_acquired = false
          @lock_id = nil
          @lock_acquired_at = nil
          @stats[:locks_released] += 1

          true
        end
      end

      def lock_acquired?
        @lock_acquired
      end

      def lock_holder
        @lock.synchronize do
          return nil unless lock_exists?
          get_lock_info
        end
      end

      def lock_age
        @lock.synchronize do
          return nil unless @lock_acquired
          Time.now - @lock_acquired_at
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            lock_acquired: @lock_acquired,
            lock_id: @lock_id,
            lock_age: lock_age
          })
        end
      end

      private

      def lock_exists?
        # In production, would check if lock table exists and has a record
        false
      end

      def get_lock_info
        # In production, would read lock information from database
        ["unknown", Time.now]
      end

      def acquire_lock_force
        # In production, would insert lock record into database
      end

      def release_lock_force
        # In production, would delete lock record from database
      end

      def generate_lock_id
        "lock_#{Time.now.to_i}_#{rand(10000)}"
      end
    end
  end
end