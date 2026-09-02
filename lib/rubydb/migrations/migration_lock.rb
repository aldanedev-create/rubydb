# frozen_string_literal: true

require "time"
require "fileutils"
require "monitor"

module RubyDB
  module Migrations
    # MigrationLock - Prevents concurrent migrations
    class MigrationLock
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @lock_table = config[:lock_table] || "migration_lock"
        @lock_path = config[:lock_path] || "#{engine.path}.migration.lock"
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
        @lock = Monitor.new
        @lock_file = nil
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
          begin
            acquire_lock_force
          rescue Errno::EACCES, Errno::EAGAIN, Errno::EWOULDBLOCK
            @stats[:lock_contention] += 1
            @stats[:locks_failed] += 1
            return false
          end
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
        !@lock_file.nil?
      end

      def get_lock_info
        [@lock_id || "external", @lock_acquired_at || Time.now]
      end

      def acquire_lock_force
        FileUtils.mkdir_p(File.dirname(@lock_path))
        file = File.open(@lock_path, "a+")
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          file.close
          raise Errno::EWOULDBLOCK
        end
        @lock_file = file
      end

      def release_lock_force
        return unless @lock_file
        @lock_file.flock(File::LOCK_UN)
        @lock_file.close
        @lock_file = nil
      end

      def generate_lock_id
        "lock_#{Time.now.to_i}_#{rand(10000)}"
      end
    end
  end
end
