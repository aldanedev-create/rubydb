# frozen_string_literal: true

module RubyDB
  module Client
    # ConnectionPool - Manages client connections
    class ConnectionPool
      attr_reader :config, :stats

      def initialize(config = {})
        @config = config
        @pool_size = config[:pool_size] || 5
        @connections = []
        @available = []
        @stats = {
          total_connections: 0,
          active_connections: 0,
          idle_connections: 0,
          borrowed_count: 0,
          returned_count: 0,
          created_count: 0,
          destroyed_count: 0,
          wait_count: 0,
          timeout_count: 0
        }
        @lock = Mutex.new
        @condition = ConditionVariable.new
        @initialized = false
        @shutdown = false

        # Pre-create connections
        initialize_pool
      end

      def get_connection(timeout = @config[:timeout] || 30)
        @lock.synchronize do
          @stats[:borrowed_count] += 1

          start_time = Time.now

          while true
            # Check if there are available connections
            unless @available.empty?
              conn = @available.pop
              if conn && conn.connected?
                @stats[:active_connections] += 1
                return conn
              else
                # Remove dead connection
                remove_connection(conn) if conn
              end
            end

            # Check if we can create a new connection
            if @connections.size < @pool_size
              conn = create_connection
              @stats[:active_connections] += 1
              return conn
            end

            # Wait for a connection to become available
            if Time.now - start_time > timeout
              @stats[:timeout_count] += 1
              raise ClientError, "Connection pool timeout: no connections available"
            end

            @stats[:wait_count] += 1
            @condition.wait(@lock, 0.1)
          end
        end
      end

      def release_connection(connection)
        @lock.synchronize do
          return unless connection

          @stats[:returned_count] += 1
          @stats[:active_connections] -= 1

          if connection.connected?
            @available << connection
            @condition.signal
          else
            remove_connection(connection)
          end
        end
      end

      def close_all
        @lock.synchronize do
          @shutdown = true

          @connections.each do |conn|
            conn.disconnect if conn.connected?
          end

          @connections.clear
          @available.clear

          @stats[:active_connections] = 0
          @stats[:idle_connections] = 0
        end
      end

      def active_count
        @stats[:active_connections]
      end

      def idle_count
        @available.size
      end

      def total_count
        @connections.size
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            pool_size: @pool_size,
            total: total_count,
            active: active_count,
            idle: idle_count,
            available: @available.size,
            shutdown: @shutdown
          })
        end
      end

      private

      def initialize_pool
        @lock.synchronize do
          return if @initialized

          # Create initial connections
          @pool_size.times do
            conn = create_connection
            @available << conn
          end

          @initialized = true
        end
      end

      def create_connection
        conn = Connection.new(@config)
        conn.connect
        @connections << conn
        @stats[:total_connections] += 1
        @stats[:created_count] += 1
        conn
      rescue => e
        raise ClientError, "Failed to create connection: #{e.message}"
      end

      def remove_connection(connection)
        return unless connection

        connection.disconnect if connection.connected?
        @connections.delete(connection)
        @available.delete(connection)
        @stats[:total_connections] -= 1
        @stats[:destroyed_count] += 1
      end
    end
  end
end