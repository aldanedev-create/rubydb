# frozen_string_literal: true

module RubyDB
  module Monitoring
    # Health - Health checking
    class Health
      attr_reader :stats

      # Health statuses
      STATUS_HEALTHY = :healthy
      STATUS_DEGRADED = :degraded
      STATUS_UNHEALTHY = :unhealthy
      STATUS_UNKNOWN = :unknown

      def initialize(engine, config = {})
        @engine = engine
        @config = config
        @checks = {}
        @status = STATUS_UNKNOWN
        @last_check = nil
        @details = {}
        @stats = {
          checks_performed: 0,
          checks_passed: 0,
          checks_failed: 0,
          status_changes: 0
        }
        @lock = Mutex.new
        @check_interval = config[:check_interval] || 30
        @check_thread = nil
        @running = false

        # Register default checks
        register_default_checks

        start_check_thread if config[:auto_check] != false
      end

      def register_check(name, &block)
        @checks[name] = block
      end

      def check
        @lock.synchronize do
          @stats[:checks_performed] += 1
          @last_check = Time.now
          @details = {}

          results = {}

          @checks.each do |name, check|
            begin
              result = check.call(@engine)
              results[name] = result
              @details[name] = result

              if result[:status] == STATUS_HEALTHY
                @stats[:checks_passed] += 1
              else
                @stats[:checks_failed] += 1
              end
            rescue => e
              results[name] = { status: STATUS_UNHEALTHY, error: e.message }
              @details[name] = { status: STATUS_UNHEALTHY, error: e.message }
              @stats[:checks_failed] += 1
            end
          end

          # Determine overall status
          old_status = @status
          if results.values.all? { |r| r[:status] == STATUS_HEALTHY }
            @status = STATUS_HEALTHY
          elsif results.values.any? { |r| r[:status] == STATUS_UNHEALTHY }
            @status = STATUS_UNHEALTHY
          else
            @status = STATUS_DEGRADED
          end

          if @status != old_status
            @stats[:status_changes] += 1
          end

          {
            status: @status,
            timestamp: @last_check.iso8601,
            checks: results
          }
        end
      end

      # Liveness answers whether the monitoring process is responsive. It
      # deliberately does not touch storage or replication dependencies.
      def liveness
        {
          status: STATUS_HEALTHY,
          live: true,
          timestamp: Time.now.iso8601
        }
      end

      # Readiness answers whether the database can safely receive work. It
      # runs the configured dependency checks and never reports ready when a
      # check is unhealthy.
      def readiness
        result = check
        {
          status: result[:status],
          ready: result[:status] == STATUS_HEALTHY,
          timestamp: result[:timestamp],
          checks: result[:checks]
        }
      end

      def status
        @status
      end

      def healthy?
        @status == STATUS_HEALTHY
      end

      def degraded?
        @status == STATUS_DEGRADED
      end

      def unhealthy?
        @status == STATUS_UNHEALTHY
      end

      def details
        @details.dup
      end

      def last_check
        @last_check
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            status: @status,
            checks_count: @checks.size,
            last_check: @last_check&.iso8601,
            running: @running,
            check_interval: @check_interval
          })
        end
      end

      private

      def register_default_checks
        register_check("connection") do |engine|
          if engine.connected?
            { status: STATUS_HEALTHY, message: "Connected" }
          else
            { status: STATUS_UNHEALTHY, message: "Disconnected" }
          end
        end

        register_check("storage") do |engine|
          if engine.storage_available?
            { status: STATUS_HEALTHY, message: "Storage available" }
          else
            { status: STATUS_UNHEALTHY, message: "Storage unavailable" }
          end
        end

        register_check("memory") do |engine|
          if engine.memory_usage < 0.9
            { status: STATUS_HEALTHY, message: "Memory usage normal" }
          elsif engine.memory_usage < 0.95
            { status: STATUS_DEGRADED, message: "Memory usage high" }
          else
            { status: STATUS_UNHEALTHY, message: "Memory usage critical" }
          end
        end

        register_check("replication") do |engine|
          if engine.replication_healthy?
            { status: STATUS_HEALTHY, message: "Replication healthy" }
          else
            { status: STATUS_UNHEALTHY, message: "Replication unhealthy" }
          end
        end

        register_check("connections") do |engine|
          usage = engine.connection_usage
          if usage < 0.8
            { status: STATUS_HEALTHY, message: "Connection usage normal" }
          elsif usage < 0.95
            { status: STATUS_DEGRADED, message: "Connection usage high" }
          else
            { status: STATUS_UNHEALTHY, message: "Connection usage critical" }
          end
        end

        register_check("wal") do |engine|
          if engine.wal_healthy?
            { status: STATUS_HEALTHY, message: "WAL healthy" }
          else
            { status: STATUS_UNHEALTHY, message: "WAL unhealthy" }
          end
        end
      end

      def start_check_thread
        @running = true
        @check_thread = Thread.new do
          while @running
            sleep(@check_interval)
            begin
              check
            rescue => e
              # Continue running
            end
          end
        end
      end
    end
  end
end
