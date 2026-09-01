# frozen_string_literal: true

module RubyDB
  module Server
    # ConnectionPool - Manages database connections
    class ConnectionPool
      attr_reader :stats

      def initialize(config, protocol)
        @config = config
        @protocol = protocol
        @max_connections = config[:max_connections] || 100
        @connections = {}
        @connection_counter = 0
        @stats = {
          total_connections: 0,
          active_connections: 0,
          idle_connections: 0,
          rejected_connections: 0,
          connection_errors: 0,
          avg_connection_time_ms: 0,
          total_connection_time_ms: 0
        }
        @lock = Mutex.new
        @running = false
        @cleanup_thread = nil
        @cleanup_interval = config[:cleanup_interval] || 60
        @idle_timeout = config[:idle_timeout] || 300
      end

      def start
        @lock.synchronize do
          return if @running

          @running = true
          @cleanup_thread = Thread.new { cleanup_loop }
          true
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          if @cleanup_thread
            @cleanup_thread.kill
            @cleanup_thread = nil
          end

          close_all
          true
        end
      end

      def add_connection(client)
        @lock.synchronize do
          if @connections.size >= @max_connections
            client.close
            @stats[:rejected_connections] += 1
            return false
          end

          start_time = Time.now
          conn_id = next_connection_id
          connection = Connection.new(client, conn_id, @config)

          @connections[conn_id] = connection

          elapsed_ms = (Time.now - start_time) * 1000
          @stats[:total_connection_time_ms] += elapsed_ms
          @stats[:avg_connection_time_ms] = @stats[:total_connection_time_ms] / @stats[:total_connections] if @stats[:total_connections] > 0

          true
        end
      end

      def get_connection(id)
        @lock.synchronize do
          @connections[id]
        end
      end

      def remove_connection(id)
        @lock.synchronize do
          conn = @connections.delete(id)
          conn&.close
          conn
        end
      end

      def close_all
        @lock.synchronize do
          @connections.each do |id, conn|
            conn.close
          end
          @connections.clear
        end
      end

      def can_accept?
        @connections.size < @max_connections
      end

      def active_count
        @lock.synchronize do
          @connections.values.count { |c| !c.closed? && !c.idle? }
        end
      end

      def idle_count
        @lock.synchronize do
          @connections.values.count { |c| !c.closed? && c.idle? }
        end
      end

      def total_connections
        @connections.size
      end

      def running?
        @running
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            current_connections: @connections.size,
            active_connections: active_count,
            idle_connections: idle_count,
            max_connections: @max_connections,
            running: @running
          })
        end
      end

      private

      def next_connection_id
        @connection_counter += 1
      end

      def cleanup_loop
        while @running
          sleep(@cleanup_interval)

          @lock.synchronize do
            @connections.each do |id, conn|
              # Remove idle connections
              if conn.idle?
                conn.close
                @connections.delete(id)
              end
            end
          end
        end
      end
    end
  end
end