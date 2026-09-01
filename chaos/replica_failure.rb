# frozen_string_literal: true

module RubyDB
  module Chaos
    # ReplicaFailure - Simulates replica failures
    class ReplicaFailure
      attr_reader :stats

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @failure_probability = config[:probability] || 0.05
        @max_failures = config[:max_failures] || 5
        @failure_types = [:crash, :disconnect, :lag, :corrupt, :split_brain]
        @stats = {
          failures: 0,
          crashes: 0,
          disconnects: 0,
          lags: 0,
          corruptions: 0,
          split_brains: 0,
          recovered: 0,
          failed_recoveries: 0,
          replicas_affected: [],
          last_failure: nil
        }
        @lock = Mutex.new
        @replica_status = {}
      end

      def inject(replica_id = nil)
        @lock.synchronize do
          return if @stats[:failures] >= @max_failures

          if rand < @failure_probability
            replica_id ||= rand(1..5)
            perform_failure(replica_id)
          end
        end
      end

      def fail_replica(replica_id, failure_type = nil)
        @lock.synchronize do
          failure_type ||= @failure_types.sample
          perform_failure_type(replica_id, failure_type)
        end
      end

      def recover_replica(replica_id)
        @lock.synchronize do
          @stats[:recovered] += 1
          @replica_status[replica_id] = :healthy
          true
        end
      end

      def set_replica_lag(replica_id, lag_ms)
        @lock.synchronize do
          @stats[:lags] += 1
          @replica_status[replica_id] = { status: :lagging, lag_ms: lag_ms }
          @stats[:last_failure] = { type: :lag, time: Time.now, replica: replica_id, lag_ms: lag_ms }
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            failure_probability: @failure_probability,
            max_failures: @max_failures,
            active_replicas: @replica_status.size,
            healthy_replicas: @replica_status.count { |_, s| s == :healthy }
          })
        end
      end

      private

      def perform_failure(replica_id)
        failure_type = @failure_types.sample
        perform_failure_type(replica_id, failure_type)
      end

      def perform_failure_type(replica_id, failure_type)
        @stats[:failures] += 1
        @stats[:replicas_affected] << replica_id unless @stats[:replicas_affected].include?(replica_id)
        @stats[:last_failure] = { type: failure_type, time: Time.now, replica: replica_id }

        case failure_type
        when :crash
          perform_crash(replica_id)
        when :disconnect
          perform_disconnect(replica_id)
        when :lag
          perform_lag(replica_id)
        when :corrupt
          perform_corrupt(replica_id)
        when :split_brain
          perform_split_brain(replica_id)
        end
      end

      def perform_crash(replica_id)
        @stats[:crashes] += 1
        @replica_status[replica_id] = :crashed

        if @engine.respond_to?(:remove_replica)
          @engine.remove_replica(replica_id)
        end
      end

      def perform_disconnect(replica_id)
        @stats[:disconnects] += 1
        @replica_status[replica_id] = :disconnected

        if @engine.respond_to?(:disconnect_replica)
          @engine.disconnect_replica(replica_id)
        end
      end

      def perform_lag(replica_id)
        lag_ms = rand(100..10000)
        @stats[:lags] += 1
        @replica_status[replica_id] = { status: :lagging, lag_ms: lag_ms }
      end

      def perform_corrupt(replica_id)
        @stats[:corruptions] += 1
        @replica_status[replica_id] = :corrupted

        if @engine.respond_to?(:corrupt_replica)
          @engine.corrupt_replica(replica_id)
        end
      end

      def perform_split_brain(replica_id)
        @stats[:split_brains] += 1
        @replica_status[replica_id] = :split_brain

        if @engine.respond_to?(:split_brain_replica)
          @engine.split_brain_replica(replica_id)
        end
      end
    end
  end
end