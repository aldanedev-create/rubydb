# frozen_string_literal: true

require "time"
require "fileutils"

module RubyDB
  module Chaos
    # CrashProcess - Simulates process crashes
    class CrashProcess
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @crash_probability = config[:probability] || 0.1
        @crash_on_operation = config[:on_operation] || :any
        @recovery_enabled = config[:recovery] != false
        @stats = {
          crashes: 0,
          recovered: 0,
          failed_recoveries: 0,
          crash_points: [],
          last_crash: nil
        }
        @lock = Mutex.new
        @should_crash = false
        @crash_after_operation = false
      end

      def inject(operation = nil)
        @lock.synchronize do
          # Check if we should crash
          if should_crash?(operation)
            perform_crash
          end

          # Check if we should crash after operation
          if @crash_after_operation
            @crash_after_operation = false
            perform_crash
          end
        end
      end

      def inject_after(operation = nil)
        @lock.synchronize do
          @crash_after_operation = true
        end
      end

      def crash_now
        @lock.synchronize do
          perform_crash
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            crash_probability: @crash_probability,
            recovery_enabled: @recovery_enabled,
            crash_on_operation: @crash_on_operation
          })
        end
      end

      private

      def should_crash?(operation)
        return false unless @crash_on_operation == :any || @crash_on_operation == operation
        rand < @crash_probability
      end

      def perform_crash
        @stats[:crashes] += 1
        @stats[:last_crash] = Time.now
        @stats[:crash_points] << {
          time: Time.now,
          operation: @crash_on_operation,
          pid: Process.pid
        }

        # Save current state for recovery
        save_crash_state

        # Simulate crash by raising exception or killing process
        raise ChaosError, "Process crash simulated" if @config[:raise_exception]

        # In production, we would actually crash the process
        # For testing, we'll simulate recovery
        if @recovery_enabled
          recover
        end
      end

      def save_crash_state
        crash_dir = @config[:crash_dir] || "tmp/crashes"
        FileUtils.mkdir_p(crash_dir)

        state = {
          time: Time.now.iso8601,
          pid: Process.pid,
          operation: @crash_on_operation,
          engine_state: @engine.stats
        }

        File.write(
          File.join(crash_dir, "crash_#{Time.now.to_i}.json"),
          JSON.generate(state)
        )
      end

      def recover
        begin
          # Attempt recovery
          if @engine.respond_to?(:recover)
            @engine.recover
            @stats[:recovered] += 1
          else
            @stats[:failed_recoveries] += 1
          end
        rescue => e
          @stats[:failed_recoveries] += 1
          raise ChaosError, "Recovery failed: #{e.message}"
        end
      end
    end
  end
end