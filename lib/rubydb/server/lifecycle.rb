# frozen_string_literal: true

require "time"

module RubyDB
  module Server
    # Lifecycle - Manages server lifecycle events
    class Lifecycle
      attr_reader :state, :stats

      # Lifecycle states
      STATE_INIT = :init
      STATE_STARTING = :starting
      STATE_RUNNING = :running
      STATE_STOPPING = :stopping
      STATE_STOPPED = :stopped
      STATE_FAILED = :failed
      STATE_RESTARTING = :restarting

      def initialize(server, config = {})
        @server = server
        @config = config
        @state = STATE_INIT
        @health_check_interval = config[:health_check_interval] || 30
        @graceful_timeout = config[:graceful_timeout] || 30
        @max_restart_attempts = config[:max_restart_attempts] || 3
        @restart_attempts = 0
        @stats = {
          state_changes: 0,
          start_count: 0,
          stop_count: 0,
          restart_count: 0,
          failure_count: 0,
          uptime_seconds: 0,
          last_state_change: nil,
          health_checks: 0,
          health_check_failures: 0
        }
        @lock = Mutex.new
        @health_thread = nil
        @running = false
        @shutdown = false
        @started_at = nil

        # Register signal handlers
        register_signal_handlers
      end

      def start
        @lock.synchronize do
          return if @state == STATE_RUNNING

          change_state(STATE_STARTING)
          @started_at = Time.now

          begin
            # Start the server
            @server.start
            change_state(STATE_RUNNING)
            @stats[:start_count] += 1
            @restart_attempts = 0

            # Start health check
            start_health_check

            true
          rescue => e
            change_state(STATE_FAILED)
            @stats[:failure_count] += 1
            raise
          end
        end
      end

      def stop(graceful = true)
        @lock.synchronize do
          return if @state == STATE_STOPPED

          change_state(STATE_STOPPING)

          begin
            if graceful
              # Graceful shutdown
              @server.stop
            else
              # Force shutdown
              @server.stop
            end

            change_state(STATE_STOPPED)
            @stats[:stop_count] += 1
            @running = false

            true
          rescue => e
            change_state(STATE_FAILED)
            @stats[:failure_count] += 1
            raise
          end
        end
      end

      def restart(graceful = true)
        @lock.synchronize do
          change_state(STATE_RESTARTING)
          @stats[:restart_count] += 1

          begin
            stop(graceful)
            start
            true
          rescue => e
            change_state(STATE_FAILED)
            @stats[:failure_count] += 1
            false
          end
        end
      end

      def health_check
        @lock.synchronize do
          @stats[:health_checks] += 1

          begin
            # Check if server is running
            unless @server.running?
              @stats[:health_check_failures] += 1
              return false
            end

            # Check connection pool
            pool = @server.connection_pool
            if pool && pool.total_connections > 0
              if pool.respond_to?(:healthy?) && !pool.healthy?
                @stats[:health_check_failures] += 1
                return false
              end
            end

            true
          rescue => e
            @stats[:health_check_failures] += 1
            false
          end
        end
      end

      def running?
        @state == STATE_RUNNING
      end

      def stats
        @lock.synchronize do
          elapsed = @started_at ? (Time.now - @started_at).to_i : 0
          @stats[:uptime_seconds] = elapsed

          @stats.merge({
            state: @state,
            running: running?,
            started_at: @started_at&.iso8601,
            restart_attempts: @restart_attempts,
            max_restart_attempts: @max_restart_attempts,
            graceful_timeout: @graceful_timeout
          })
        end
      end

      private

      def change_state(new_state)
        @state = new_state
        @stats[:state_changes] += 1
        @stats[:last_state_change] = Time.now
      end

      def start_health_check
        return if @health_thread

        @running = true
        @health_thread = Thread.new do
          while @running && !@shutdown
            sleep(@health_check_interval)

            unless health_check
              # Health check failed
              @stats[:health_check_failures] += 1

              if @restart_attempts < @max_restart_attempts
                @restart_attempts += 1
                restart
              else
                change_state(STATE_FAILED)
                @running = false
              end
            end
          end
        end
      end

      def register_signal_handlers
        # SIGINT - Graceful shutdown
        trap("INT") do
          puts "\nReceived SIGINT, shutting down gracefully..."
          @shutdown = true
          stop(true)
        end

        # SIGTERM - Graceful shutdown
        trap("TERM") do
          puts "Received SIGTERM, shutting down gracefully..."
          @shutdown = true
          stop(true)
        end

        # SIGHUP - Restart
        begin
          trap("HUP") do
            puts "Received SIGHUP, restarting..."
            restart
          end
        rescue ArgumentError
          # Windows does not expose SIGHUP; restart remains available via
          # the explicit server API.
        end
      end
    end
  end
end
