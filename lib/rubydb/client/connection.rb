# frozen_string_literal: true

require "socket"
require "json"
require "time"

module RubyDB
  module Client
    # Connection - Client connection to database server
    class Connection
      attr_reader :config, :socket, :stats

      def initialize(config = {})
        @config = config
        @socket = nil
        @connected = false
        @protocol = nil
        @authenticated = false
        @session_id = nil
        @stats = {
          bytes_sent: 0,
          bytes_received: 0,
          messages_sent: 0,
          messages_received: 0,
          errors: 0,
          reconnects: 0
        }
        @lock = Mutex.new
        @buffer = ""
      end

      def connect
        @lock.synchronize do
          return if @connected

          begin
            @socket = TCPSocket.new(@config[:host], @config[:port])

            # Set timeouts
            if @config[:timeout]
              @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [@config[:timeout], 0].pack("l_2"))
              @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [@config[:timeout], 0].pack("l_2"))
            end

            # Initialize protocol
            @protocol = Protocol::Protocol.new(
              format: @config[:format] || :json,
              compression: @config[:compress] || false,
              encryption: @config[:ssl] || false
            )

            # Perform handshake
            perform_handshake

            @connected = true

          rescue => e
            raise ConnectionError, "Connection failed: #{e.message}"
          end
        end
      end

      def disconnect
        @lock.synchronize do
          return unless @connected

          begin
            # Send terminate message
            send_message(Protocol::Message.new(Protocol::Message::TYPE_TERMINATE))
          rescue
            # Ignore errors on disconnect
          end

          @socket.close if @socket
          @socket = nil
          @connected = false
          @authenticated = false
        end
      end

      def connected?
        @connected && @socket && !@socket.closed?
      end

      def send_query(sql, params = [])
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(
            Protocol::Message::TYPE_QUERY,
            { sql: sql, params: params }
          )

          send_message(message)
          receive_message
        end
      end

      def send_prepare(sql)
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(
            Protocol::Message::TYPE_PREPARE,
            { sql: sql }
          )

          send_message(message)
          receive_message
        end
      end

      def send_execute(statement_id, params = [])
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(
            Protocol::Message::TYPE_EXECUTE,
            { statement_id: statement_id, params: params }
          )

          send_message(message)
          receive_message
        end
      end

      def send_close(statement_id)
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(
            Protocol::Message::TYPE_CLOSE,
            { statement_id: statement_id }
          )

          send_message(message)
          receive_message
        end
      end

      def send_begin(options = {})
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(
            Protocol::Message::TYPE_BEGIN,
            options
          )

          send_message(message)
          receive_message
        end
      end

      def send_commit
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(Protocol::Message::TYPE_COMMIT)
          send_message(message)
          receive_message
        end
      end

      def send_rollback
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(Protocol::Message::TYPE_ROLLBACK)
          send_message(message)
          receive_message
        end
      end

      def send_ping
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(Protocol::Message::TYPE_PING)
          send_message(message)
          receive_message
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            connected: @connected,
            authenticated: @authenticated,
            host: @config[:host],
            port: @config[:port]
          })
        end
      end

      private

      def ensure_connected
        unless @connected
          connect
        end
      end

      def send_message(message)
        data = @protocol.encoder.encode(message)
        @socket.write(data)
        @socket.flush

        @stats[:bytes_sent] += data.bytesize
        @stats[:messages_sent] += 1
      end

      def receive_message
        data = @socket.read
        @stats[:bytes_received] += data.bytesize
        @stats[:messages_received] += 1

        @protocol.decoder.decode(data, @protocol.encoder.format)
      rescue => e
        @stats[:errors] += 1
        raise ConnectionError, "Receive failed: #{e.message}"
      end

      def perform_handshake
        # Send handshake request
        handshake_msg = Protocol::Message.new(
          Protocol::Message::TYPE_HANDSHAKE,
          {
            protocol_version: Protocol::ProtocolVersion.current,
            client_name: "RubyDB Client",
            client_version: RubyDB::VERSION,
            username: @config[:username],
            database: @config[:database]
          }
        )

        send_message(handshake_msg)
        response = receive_message

        if response.type == Protocol::Message::TYPE_HANDSHAKE_RESPONSE
          if response.payload[:success]
            # Send authentication
            auth_msg = Protocol::Message.new(
              Protocol::Message::TYPE_AUTHENTICATION_RESPONSE,
              {
                username: @config[:username],
                password: @config[:password],
                auth_method: @config[:auth_method] || "none"
              }
            )

            send_message(auth_msg)
            auth_response = receive_message

            if auth_response.type == Protocol::Message::TYPE_AUTHENTICATION
              @authenticated = true
              @session_id = auth_response.payload[:session_id]
            else
              raise ConnectionError, "Authentication failed"
            end
          else
            raise ConnectionError, "Handshake failed: #{response.payload[:error]}"
          end
        else
          raise ConnectionError, "Unexpected handshake response"
        end
      end
    end
  end
end