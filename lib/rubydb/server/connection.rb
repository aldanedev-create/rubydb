# frozen_string_literal: true

require "time"

module RubyDB
  module Server
    # Connection - Represents a client connection
    class Connection
      attr_reader :id, :client, :remote_addr, :remote_port
      attr_reader :created_at, :last_activity, :state, :session
      attr_reader :bytes_received, :bytes_sent, :requests_processed

      # Connection states
      STATE_INIT = :init
      STATE_HANDSHAKING = :handshaking
      STATE_AUTHENTICATING = :authenticating
      STATE_AUTHENTICATED = :authenticated
      STATE_READY = :ready
      STATE_BUSY = :busy
      STATE_CLOSED = :closed

      def initialize(client, id, config = {})
        @id = id
        @client = client
        @remote_addr = client.peeraddr[2] rescue "unknown"
        @remote_port = client.peeraddr[1] rescue 0
        @config = config
        @created_at = Time.now
        @last_activity = Time.now
        @state = STATE_INIT
        @bytes_received = 0
        @bytes_sent = 0
        @requests_processed = 0
        @session = nil
        @session_id = nil
        @authenticated = false
        @username = nil
        @read_timeout = config[:read_timeout] || 30
        @write_timeout = config[:write_timeout] || 30
        @idle_timeout = config[:idle_timeout] || 300
        @buffer = ""
        @lock = Mutex.new
        @closed = false
        @pending_requests = []
      end

      def handshake(protocol)
        @lock.synchronize do
          return false if @closed

          @state = STATE_HANDSHAKING

          begin
            # Read handshake request
            data = read_data(protocol)

            # Process handshake
            response = protocol.handshake.start(data)

            # Send handshake response
            write_data(protocol, response)

            @state = STATE_AUTHENTICATING
            true

          rescue => e
            close
            false
          end
        end
      end

      def authenticate(credentials)
        @lock.synchronize do
          return false if @closed || @state == STATE_CLOSED

          @state = STATE_AUTHENTICATING

          begin
            # Authenticate
            @authenticated = @session&.authenticate(credentials) || false

            if @authenticated
              @state = STATE_AUTHENTICATED
              @username = credentials[:username]
              true
            else
              @state = STATE_CLOSED
              close
              false
            end

          rescue => e
            @state = STATE_CLOSED
            close
            false
          end
        end
      end

      def ready?
        @state == STATE_READY
      end

      def busy?
        @state == STATE_BUSY
      end

      def authenticated?
        @authenticated
      end

      def closed?
        @closed
      end

      def idle?
        Time.now - @last_activity > @idle_timeout
      end

      def process_request(request, protocol)
        @lock.synchronize do
          return false if @closed

          @state = STATE_BUSY
          @last_activity = Time.now
          @requests_processed += 1

          begin
            # Process request through session
            response = @session&.process(request) || error_response("No session")

            # Send response
            write_data(protocol, response)

            @state = STATE_READY
            true

          rescue => e
            @state = STATE_READY
            false
          end
        end
      end

      def close
        @lock.synchronize do
          return if @closed

          @state = STATE_CLOSED
          @closed = true

          if @client
            @client.close rescue nil
            @client = nil
          end

          if @session
            @session.close
            @session = nil
          end

          true
        end
      end

      def to_hash
        {
          id: @id,
          remote_addr: @remote_addr,
          remote_port: @remote_port,
          state: @state,
          authenticated: @authenticated,
          username: @username,
          created_at: @created_at.iso8601,
          last_activity: @last_activity.iso8601,
          bytes_received: @bytes_received,
          bytes_sent: @bytes_sent,
          requests_processed: @requests_processed,
          idle_time: (Time.now - @last_activity).round(2)
        }
      end

      private

      def read_data(protocol)
        data = ""

        while true
          chunk = @client.recv(4096)
          break if chunk.empty?
          data << chunk
          @bytes_received += chunk.bytesize
          break if data.bytesize >= @config[:max_request_size]
        end

        data
      end

      def write_data(protocol, data)
        if data.is_a?(String)
          @client.write(data)
          @bytes_sent += data.bytesize
        else
          encoded = protocol.encoder.encode(data)
          @client.write(encoded)
          @bytes_sent += encoded.bytesize
        end
        @client.flush
      end

      def error_response(message)
        {
          success: false,
          error: message,
          timestamp: Time.now.iso8601
        }
      end
    end
  end
end