# frozen_string_literal: true

require "socket"
require "timeout"

module RubyDB
  module Protocol
    class Protocol
      attr_reader :encoder, :decoder, :handshake, :capabilities, :stats

      def initialize(options = {})
        @options = options
        @encoder = Encoder.new(options[:format] || Encoder::FORMAT_JSON, options)
        @decoder = Decoder.new(options)
        @handshake = Handshake.new(options[:server_info])
        @capabilities = Capabilities.default_server
        @buffer = ""
        @chunk_size = options[:chunk_size] || 4096
        @socket = nil
        @connected = false
        @authenticated = false
        @stats = {
          messages_sent: 0,
          messages_received: 0,
          bytes_sent: 0,
          bytes_received: 0,
          errors: 0,
          reconnects: 0,
          connection_time: 0
        }
        @lock = Mutex.new
        @read_timeout = options[:read_timeout] || 30
        @write_timeout = options[:write_timeout] || 30
      end

      def connect(host, port)
        @lock.synchronize do
          start_time = Time.now

          begin
            @socket = TCPSocket.new(host, port)
            @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

            if @read_timeout
              @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [@read_timeout, 0].pack("l_2"))
            end

            if @write_timeout
              @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [@write_timeout, 0].pack("l_2"))
            end

            @connected = true
            @stats[:connection_time] = (Time.now - start_time) * 1000

            # Perform handshake
            perform_handshake

            true

          rescue => e
            @stats[:errors] += 1
            @connected = false
            raise ProtocolError, "Connection failed: #{e.message}"
          end
        end
      end

      def disconnect
        @lock.synchronize do
          if @socket
            begin
              send_message(Message.new(Message::TYPE_TERMINATE))
            rescue
              # Ignore errors on disconnect
            end
            @socket.close
          end

          @socket = nil
          @connected = false
          @authenticated = false
          true
        end
      end

      def send_message(message)
        @lock.synchronize do
          raise ProtocolError, "Not connected" unless @connected

          begin
            data = @encoder.encode(message)
            @socket.write(data)
            @socket.flush

            @stats[:messages_sent] += 1
            @stats[:bytes_sent] += data.bytesize

            true
          rescue => e
            @stats[:errors] += 1
            raise ProtocolError, "Send failed: #{e.message}"
          end
        end
      end

      def receive_message(timeout = @read_timeout)
        @lock.synchronize do
          raise ProtocolError, "Not connected" unless @connected

          begin
            Timeout.timeout(timeout) do
              data = read_data
              @stats[:bytes_received] += data.bytesize
              @stats[:messages_received] += 1

              @decoder.decode(data, @encoder.format)
            end
          rescue Timeout::Error
            @stats[:errors] += 1
            raise ProtocolError, "Receive timeout"
          rescue => e
            @stats[:errors] += 1
            raise ProtocolError, "Receive failed: #{e.message}"
          end
        end
      end

      def query(sql, params = [])
        message = Message.new(Message::TYPE_QUERY, { sql: sql, params: params })
        send_message(message)
        receive_message
      end

      def prepare(sql)
        message = Message.new(Message::TYPE_PREPARE, { sql: sql })
        send_message(message)
        receive_message
      end

      def execute(statement_id, params = [])
        message = Message.new(Message::TYPE_EXECUTE, { statement_id: statement_id, params: params })
        send_message(message)
        receive_message
      end

      def close_statement(statement_id)
        message = Message.new(Message::TYPE_CLOSE, { statement_id: statement_id })
        send_message(message)
        receive_message
      end

      def begin_transaction
        message = Message.new(Message::TYPE_BEGIN)
        send_message(message)
        receive_message
      end

      def commit
        message = Message.new(Message::TYPE_COMMIT)
        send_message(message)
        receive_message
      end

      def rollback
        message = Message.new(Message::TYPE_ROLLBACK)
        send_message(message)
        receive_message
      end

      def ping
        message = Message.new(Message::TYPE_PING)
        send_message(message)
        receive_message
      end

      def connected?
        @connected && @socket && !@socket.closed?
      end

      def authenticated?
        @authenticated
      end

      def reconnect(host, port)
        @lock.synchronize do
          disconnect
          connect(host, port)
          @stats[:reconnects] += 1
          true
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            connected: @connected,
            authenticated: @authenticated,
            handshake_state: @handshake.state,
            buffer_size: @buffer.bytesize,
            socket_info: @socket ? "#{@socket.peeraddr[2]}:#{@socket.peeraddr[1]}" : nil
          })
        end
      end

      private

      def read_data
        data = ""

        while true
          chunk = @socket.recv(@chunk_size)
          break if chunk.empty?
          data << chunk
          break if data.bytesize >= @chunk_size
        end

        data
      end

      def perform_handshake
        # Send handshake request
        handshake_msg = Message.new(
          Message::TYPE_HANDSHAKE,
          {
            protocol_version: ProtocolVersion.current,
            client_name: "RubyDB Client",
            client_version: RubyDB::VERSION
          }
        )

        send_message(handshake_msg)
        response = receive_message

        if response.type == Message::TYPE_HANDSHAKE_RESPONSE
          handshake_data = response.payload

          if handshake_data[:success]
            # Send authentication response
            auth_msg = Message.new(
              Message::TYPE_AUTHENTICATION_RESPONSE,
              {
                username: @options[:username] || "rubydb",
                password: @options[:password] || "",
                auth_method: @options[:auth_method] || "none"
              }
            )

            send_message(auth_msg)
            auth_response = receive_message

            if auth_response.type == Message::TYPE_AUTHENTICATION
              @authenticated = true
              @handshake.state = Handshake::STATE_AUTHENTICATED

              # Negotiate capabilities
              caps_msg = Message.new(
                Message::TYPE_SYNCHRONIZE,
                {
                  capabilities: Capabilities.default_client.to_hash
                }
              )

              send_message(caps_msg)
              caps_response = receive_message

              if caps_response.type == Message::TYPE_READY_FOR_QUERY
                @handshake.state = Handshake::STATE_COMPLETE
                @capabilities.negotiate(caps_response.payload[:capabilities] || 0)
                @authenticated = true
              end
            end
          else
            raise ProtocolError, "Handshake failed: #{handshake_data[:error]}"
          end
        end
      end
    end
  end
end