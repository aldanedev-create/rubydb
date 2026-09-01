# frozen_string_literal: true

require "socket"

module RubyDB
  module Server
    # Listener - Accepts incoming connections
    class Listener
      attr_reader :stats

      def initialize(config, connection_pool, worker_pool)
        @config = config
        @connection_pool = connection_pool
        @worker_pool = worker_pool
        @socket = nil
        @running = false
        @accept_thread = nil
        @stats = {
          connections_accepted: 0,
          connections_rejected: 0,
          accept_errors: 0,
          total_accept_time_ms: 0,
          avg_accept_time_ms: 0
        }
        @lock = Mutex.new
      end

      def start
        @lock.synchronize do
          return if @running

          begin
            @socket = TCPServer.new(@config[:host], @config[:port])
            @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

            @running = true
            @accept_thread = Thread.new { accept_loop }

            true
          rescue => e
            raise ServerError, "Failed to start listener: #{e.message}"
          end
        end
      end

      def stop
        @lock.synchronize do
          return unless @running

          @running = false

          if @accept_thread
            @accept_thread.kill
            @accept_thread = nil
          end

          if @socket
            @socket.close rescue nil
            @socket = nil
          end

          true
        end
      end

      def running?
        @running
      end

      private

      def accept_loop
        while @running
          begin
            start_time = Time.now

            # Accept connection with timeout
            client = @socket.accept_nonblock rescue nil

            if client
              # Check if we have capacity
              if @connection_pool.can_accept?
                @connection_pool.add_connection(client)
                @stats[:connections_accepted] += 1
              else
                client.close
                @stats[:connections_rejected] += 1
              end

              elapsed_ms = (Time.now - start_time) * 1000
              @stats[:total_accept_time_ms] += elapsed_ms
              @stats[:avg_accept_time_ms] = @stats[:total_accept_time_ms] / @stats[:connections_accepted] if @stats[:connections_accepted] > 0
            end

            # Small sleep to prevent CPU spinning
            sleep(0.01)

          rescue IO::WaitReadable, Errno::EAGAIN, Errno::EWOULDBLOCK
            # No connection ready, continue
            sleep(0.01)
          rescue => e
            @stats[:accept_errors] += 1
            sleep(0.1) # Back off on error
          end
        end
      end
    end
  end
end