# frozen_string_literal: true

module RubyDB
  module Chaos
    # RandomFailure - Randomly injects various failures
    class RandomFailure
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @failure_probability = config[:probability] || 0.05
        @max_failures = config[:max_failures] || 20
        @failure_types = [
          :crash_process, :corrupt_page, :network_failure, :disk_full,
          :partial_write, :delayed_io, :replica_failure
        ]
        @stats = {
          total_failures: 0,
          by_type: Hash.new(0),
          successes: 0,
          failures: 0,
          last_failure: nil,
          components_affected: []
        }
        @lock = Mutex.new
        @components = {
          crash_process: CrashProcess.new(engine, config),
          corrupt_page: CorruptPage.new(engine, config),
          network_failure: NetworkFailure.new(engine, config),
          disk_full: DiskFull.new(engine, config),
          partial_write: PartialWrite.new(engine, config),
          delayed_io: DelayedIO.new(engine, config),
          replica_failure: ReplicaFailure.new(engine, config)
        }
        @enabled = config[:enabled] != false
      end

      def inject
        @lock.synchronize do
          return unless @enabled
          return if @stats[:total_failures] >= @max_failures

          if rand < @failure_probability
            perform_random_failure
          end
        end
      end

      def inject_specific(failure_type)
        @lock.synchronize do
          return unless @enabled

          component = @components[failure_type]
          if component && component.respond_to?(:inject)
            begin
              component.inject
              @stats[:total_failures] += 1
              @stats[:by_type][failure_type] += 1
              @stats[:successes] += 1
              @stats[:last_failure] = { type: failure_type, time: Time.now }
            rescue => e
              @stats[:failures] += 1
            end
          end
        end
      end

      def inject_batch(count)
        @lock.synchronize do
          count.times do
            inject
          end
        end
      end

      def enable
        @lock.synchronize do
          @enabled = true
        end
      end

      def disable
        @lock.synchronize do
          @enabled = false
        end
      end

      def reset
        @lock.synchronize do
          @stats[:total_failures] = 0
          @stats[:by_type].clear
          @stats[:successes] = 0
          @stats[:failures] = 0
          @stats[:last_failure] = nil
          @stats[:components_affected].clear
        end
      end

      def stats
        @lock.synchronize do
          component_stats = @components.transform_values(&:stats)

          @stats.merge({
            failure_probability: @failure_probability,
            max_failures: @max_failures,
            enabled: @enabled,
            components: component_stats
          })
        end
      end

      private

      def perform_random_failure
        failure_type = @failure_types.sample
        component = @components[failure_type]

        if component && component.respond_to?(:inject)
          begin
            component.inject
            @stats[:total_failures] += 1
            @stats[:by_type][failure_type] += 1
            @stats[:successes] += 1
            @stats[:last_failure] = { type: failure_type, time: Time.now }
            @stats[:components_affected] << failure_type unless @stats[:components_affected].include?(failure_type)
          rescue => e
            @stats[:failures] += 1
          end
        end
      end
    end
  end
end