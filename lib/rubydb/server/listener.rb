# frozen_string_literal: true

require "socket"
require "openssl"

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
        @ssl_enabled = false
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
            tcp_socket = TCPServer.new(@config[:host], @config[:port])
            tcp_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

            ssl = @config[:ssl] || {}
            if ssl == true || ssl[:enabled] || ssl["enabled"]
              ssl = {} if ssl == true
              context = OpenSSL::SSL::SSLContext.new
              context.cert = OpenSSL::X509::Certificate.new(File.binread(ssl[:cert_file] || ssl["cert_file"]))
              context.key = OpenSSL::PKey.read(File.binread(ssl[:key_file] || ssl["key_file"]))
              context.ca_file = ssl[:ca_file] || ssl["ca_file"] if ssl[:ca_file] || ssl["ca_file"]
              context.verify_mode = (ssl[:verify_peer] || ssl["verify_peer"]) ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
              context.min_version = (ssl[:min_version] || ssl["min_version"] || :TLS1_2)
              context.max_version = (ssl[:max_version] || ssl["max_version"]) if ssl[:max_version] || ssl["max_version"]
              @socket = OpenSSL::SSL::SSLServer.new(tcp_socket, context)
              @ssl_enabled = true
            else
              @socket = tcp_socket
            end

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
          @ssl_enabled = false

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

            # SSLServer performs the TLS handshake while accepting. Keep that
            # operation blocking so a non-blocking handshake is not discarded
            # and left waiting forever on the client.
            client = if @ssl_enabled
              @socket.accept
            else
              candidate = @socket.accept_nonblock(exception: false)
              candidate.is_a?(IO) ? candidate : nil
            end

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
            next if @ssl_enabled
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
