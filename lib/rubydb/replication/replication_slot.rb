# frozen_string_literal: true

require "time"
require "set"

module RubyDB
  module Replication
    # Durable slot state is represented by the primary while the replication
    # catalog is still file-backed. A slot retains the last acknowledged LSN
    # and prevents accidental reuse of a replica identity.
    class ReplicationSlot
      attr_reader :name, :primary
      attr_accessor :confirmed_lsn

      def initialize(name, primary)
        @name = name.to_s
        @primary = primary
        @confirmed_lsn = 0
      end

      def advance(lsn)
        @confirmed_lsn = [@confirmed_lsn, lsn.to_i].max
      end
    end

    # Failover - Handles automatic failover
    class Failover
      attr_reader :stats

      # Failover states
      STATE_NORMAL = :normal
      STATE_HEALTH_CHECK = :health_check
      STATE_DETECTED = :detected
      STATE_FAILING_OVER = :failing_over
      STATE_PROMOTING = :promoting
      STATE_VERIFYING = :verifying
      STATE_COMPLETE = :complete
      STATE_FAILED = :failed

      def initialize(replication_manager, config = {})
        @replication_manager = replication_manager
        @config = config
        @state = STATE_NORMAL
        @failover_triggered = false
        @failover_start_time = nil
        @candidate_replicas = []
        @chosen_candidate = nil
        @health_check_history = []
        @stats = {
          failovers: 0,
          successful_failovers: 0,
          failed_failovers: 0,
          total_failover_time_ms: 0,
          avg_failover_time_ms: 0,
          last_failover_time: nil,
          last_failover_result: nil,
          health_check_failures: 0,
          consecutive_failures: 0
        }
        @lock = Mutex.new
        @running = false
        @failover_thread = nil
        @failover_timeout = config[:timeout] || 30
        @check_interval = config[:check_interval] || 5
        @max_consecutive_failures = config[:max_consecutive_failures] || 3
        @failover_trigger = config[:trigger] || :auto
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @state = STATE_NORMAL
          @failover_thread = Thread.new { failover_loop }

          puts "Failover handler started"
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          @failover_thread&.kill
          @failover_thread = nil

          puts "Failover handler stopped"
          true
        end
      end

      def trigger_failover(reason = "manual trigger")
        @lock.synchronize do
          return false if @failover_triggered

          @failover_triggered = true
          @failover_start_time = Time.now
          @stats[:failovers] += 1

          Thread.new do
            execute_failover(reason)
          end

          true
        end
      end

      def health_check
        trigger_reason = nil
        result = @lock.synchronize do
          result = @replication_manager.health_check

          @health_check_history << {
            timestamp: Time.now,
            result: result
          }

          if @health_check_history.size > 100
            @health_check_history.shift
          end

          if result[:healthy] == false
            @stats[:health_check_failures] += 1
            @stats[:consecutive_failures] += 1

            if @stats[:consecutive_failures] >= @max_consecutive_failures &&
               @failover_trigger == :auto &&
               !@failover_triggered
              trigger_reason = "health check failures"
            end
          else
            @stats[:consecutive_failures] = 0
          end

          result
        end
        trigger_failover(trigger_reason) if trigger_reason
        result
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            state: @state,
            running: @running,
            failover_triggered: @failover_triggered,
            consecutive_failures: @stats[:consecutive_failures],
            health_check_history_size: @health_check_history.size
          })
        end
      end

      private

      def failover_loop
        while @running
          sleep(@check_interval)
          begin
            health_check
          rescue => e
            # Log error but continue
          end
        end
      end

      def execute_failover(reason)
        @lock.synchronize do
          @state = STATE_DETECTED
          start_time = Time.now

          begin
            # Step 1: Find candidate replicas
            @state = STATE_HEALTH_CHECK
            candidates = find_candidate_replicas

            if candidates.empty?
              @state = STATE_FAILED
              @stats[:failed_failovers] += 1
              return failover_result(false, "No candidate replicas found")
            end

            # Step 2: Choose best candidate
            @state = STATE_PROMOTING
            @chosen_candidate = choose_best_candidate(candidates)

            unless @chosen_candidate
              @state = STATE_FAILED
              @stats[:failed_failovers] += 1
              return failover_result(false, "No suitable candidate found")
            end

            # Step 3: Promote candidate
            @state = STATE_FAILING_OVER
            promote_result = promote_candidate(@chosen_candidate)

            unless promote_result[:success]
              @state = STATE_FAILED
              @stats[:failed_failovers] += 1
              return failover_result(false, "Promotion failed: #{promote_result[:error]}")
            end

            # Step 4: Verify promotion
            @state = STATE_VERIFYING
            verify_result = verify_promotion(@chosen_candidate)

            unless verify_result[:success]
              @state = STATE_FAILED
              @stats[:failed_failovers] += 1
              return failover_result(false, "Verification failed: #{verify_result[:error]}")
            end

            # Step 5: Complete failover
            @state = STATE_COMPLETE
            @stats[:successful_failovers] += 1

            elapsed_ms = (Time.now - start_time) * 1000
            @stats[:total_failover_time_ms] += elapsed_ms
            @stats[:avg_failover_time_ms] = @stats[:total_failover_time_ms] / @stats[:successful_failovers]
            @stats[:last_failover_time] = Time.now

            failover_result(true, "Failover completed successfully", {
              candidate: @chosen_candidate[:node_id],
              elapsed_ms: elapsed_ms,
              reason: reason
            })

          rescue => e
            @state = STATE_FAILED
            @stats[:failed_failovers] += 1
            failover_result(false, "Failover failed: #{e.message}")
          ensure
            @failover_triggered = false
            @chosen_candidate = nil
          end
        end
      end

      def find_candidate_replicas
        candidates = []

        replica = @replication_manager.replica
        status = replica&.replication_status
        if replica&.running? && status && status[:state] == Replica::STATE_SYNCED
          candidates << {
            node_id: @replication_manager.replica.config[:node_id] || "replica_1",
            host: replica.primary_host,
            port: replica.primary_port,
            status: status[:state].to_s,
            lag_ms: status[:lag_ms].to_i,
            replayed_lsn: status[:last_replayed_lsn].to_i
          }
        end

        candidates
      end

      def choose_best_candidate(candidates)
        candidates.min_by { |c| [c[:lag_ms] || 0, -(c[:replayed_lsn] || 0)] }
      end

      def promote_candidate(candidate)
        result = @replication_manager.promote_to_primary
        return { success: false, error: "Promotion manager returned no result" } unless result.is_a?(Hash)

        result[:success] ? result : { success: false, error: result[:error] || "Promotion failed" }
      end

      def verify_promotion(candidate)
        mode = @replication_manager.respond_to?(:mode) ? @replication_manager.mode : nil
        return { success: false, error: "Promotion did not enter primary mode" } unless mode == ReplicationManager::MODE_PRIMARY

        health = @replication_manager.health_check
        health[:healthy] ? { success: true, health: health } : { success: false, error: "Promoted node is unhealthy" }
      end

      def failover_result(success, message, extra = {})
        started_at = @failover_start_time || Time.now
        result = {
          success: success,
          message: message,
          timestamp: Time.now.iso8601,
          elapsed_ms: (Time.now - started_at) * 1000,
          state: @state
        }.merge(extra)

        @stats[:last_failover_result] = result
        result
      end
    end
  end
end
