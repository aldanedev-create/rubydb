# frozen_string_literal: true

require "thread"
require "time"
require "monitor"

module RubyDB
  module Replication
    # ReplicationManager - Manages replication setup and coordination
    class ReplicationManager
      attr_reader :config, :primary, :replica, :stats, :mode

      # Replication modes
      MODE_OFF = :off
      MODE_PRIMARY = :primary
      MODE_REPLICA = :replica
      MODE_STANDBY = :standby

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @mode = config[:mode] || MODE_OFF
        @cluster_name = config[:cluster_name] || "rubydb_cluster"
        @node_id = config[:node_id] || generate_node_id
        @primary_host = config[:primary_host]
        @primary_port = config[:primary_port] || 7433
        @replication_port = config[:replication_port] || 7434

        @primary = nil
        @replica = nil
        @replication_slots = {}
        @health_checks = []
        @stats = {
          mode: @mode,
          node_id: @node_id,
          cluster_name: @cluster_name,
          healthy: true,
          last_health_check: nil,
          failovers: 0,
          switches: 0,
          errors: 0
        }
        @lock = Monitor.new
        @running = false
        @health_thread = nil
        @health_check_interval = config[:health_check_interval] || 10

        # Initialize based on mode
        initialize_mode
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true

          case @mode
          when MODE_PRIMARY
            @primary&.start
          when MODE_REPLICA
            @replica&.start
          end

          # Start health check
          start_health_check

          puts "Replication manager started in #{@mode} mode"
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          @health_thread&.kill
          @health_thread = nil

          @primary&.stop
          @replica&.stop

          puts "Replication manager stopped"
          true
        end
      end

      def switch_mode(new_mode, config = {})
        @lock.synchronize do
          old_mode = @mode

          # Stop current mode
          stop

          # Update config
          @mode = new_mode
          @config = @config.merge(config)

          # Initialize new mode
          initialize_mode

          # Start new mode
          start

          @stats[:switches] += 1

          { old_mode: old_mode, new_mode: new_mode }
        end
      end

      def promote_to_primary
        @lock.synchronize do
          if @mode != MODE_REPLICA
            return { success: false, error: "Not in replica mode" }
          end

          status = @replica&.replication_status
          unless status && [Replica::STATE_STREAMING, Replica::STATE_SYNCED].include?(status[:state])
            return { success: false, error: "Replica is not synchronized enough for manual promotion" }
          end

          # Promote replica to primary. Automatic promotion is intentionally
          # not attempted; callers must explicitly invoke this operation.
          @replica&.promote_to_primary

          # Switch mode
          @mode = MODE_PRIMARY

          # Create new primary
          @primary = Primary.new(@engine, @config)
          @primary.start

          @replica = nil
          @stats[:failovers] += 1

          { success: true, message: "Promoted to primary" }
        end
      end

      def demote_to_replica(primary_host, primary_port = nil)
        @lock.synchronize do
          if @mode != MODE_PRIMARY
            return { success: false, error: "Not in primary mode" }
          end

          # Stop primary
          @primary&.stop

          # Update config
          @config[:primary_host] = primary_host
          @config[:primary_port] = primary_port if primary_port
          @mode = MODE_REPLICA

          # Create new replica
          @replica = Replica.new(@engine, @config)
          @replica.start

          @primary = nil
          @stats[:switches] += 1

          { success: true, message: "Demoted to replica" }
        end
      end

      def health_check
        @lock.synchronize do
          @stats[:last_health_check] = Time.now

          result = case @mode
          when MODE_PRIMARY
            check_primary_health
          when MODE_REPLICA
            check_replica_health
          else
            { healthy: true, message: "Not in active replication mode" }
          end

          @stats[:healthy] = result[:healthy]
          @health_checks << result

          # Trim health checks
          if @health_checks.size > 100
            @health_checks.shift
          end

          result
        end
      end

      def get_replication_status
        @lock.synchronize do
          status = {
            mode: @mode,
            node_id: @node_id,
            cluster_name: @cluster_name,
            running: @running,
            healthy: @stats[:healthy],
            last_health_check: @stats[:last_health_check]&.iso8601
          }

          case @mode
          when MODE_PRIMARY
            status[:primary] = @primary&.get_replication_status
          when MODE_REPLICA
            status[:replica] = @replica&.replication_status
          end

          status
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            running: @running,
            health_checks: @health_checks.size,
            mode: @mode,
            node_id: @node_id
          })
        end
      end

      private

      def generate_node_id
        "node_#{Time.now.to_i}_#{rand(10000)}"
      end

      def initialize_mode
        case @mode
        when MODE_PRIMARY
          @primary = Primary.new(@engine, @config)
        when MODE_REPLICA
          unless @config[:primary_host]
            raise ConfigError, "Primary host required for replica mode"
          end
          @replica = Replica.new(@engine, @config)
        when MODE_OFF, MODE_STANDBY
          # No replication
        else
          @mode = MODE_OFF
        end
      end

      def start_health_check
        @health_thread = Thread.new do
          while @running
            sleep(@health_check_interval)
            begin
              health_check
            rescue => e
              @stats[:errors] += 1
            end
          end
        end
      end

      def check_primary_health
        if @primary&.running?
          { healthy: true, message: "Primary is running" }
        else
          { healthy: false, message: "Primary is not running" }
        end
      end

      def check_replica_health
        if @replica&.running?
          status = @replica.replication_status
          if status[:state] == :failed
            { healthy: false, message: "Replica in failed state" }
          else
            { healthy: true, message: "Replica is running" }
          end
        else
          { healthy: false, message: "Replica is not running" }
        end
      end
    end
  end
end
