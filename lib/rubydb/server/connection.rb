# frozen_string_literal: true

require "time"
require "monitor"

module RubyDB
  module Server
    # Connection - Represents a client connection
    class Connection
      RequestTooLarge = Class.new(StandardError)
      RequestTimeout = Class.new(StandardError)

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
        @session = Session.new(self, config) if config[:engine]
        @session_id = nil
        @authenticated = false
        @username = nil
        @read_timeout = config[:read_timeout] || 30
        @write_timeout = config[:write_timeout] || 30
        @idle_timeout = config[:idle_timeout] || 300
        @buffer = ""
        @lock = Monitor.new
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

      def start(protocol)
        @thread = Thread.new { serve(protocol) }
        true
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

      def serve(protocol)
        first = protocol.decoder.decode(read_frame, protocol.encoder.format)
        handshake = protocol.handshake.start(first.payload)
        write_data(protocol, Protocol::Message.new(Protocol::Message::TYPE_HANDSHAKE_RESPONSE, handshake))
        return close unless handshake[:success]

        auth = protocol.decoder.decode(read_frame, protocol.encoder.format)
        authenticated = protocol.handshake.authenticate(auth.payload)
        @session&.authenticate(auth.payload)
        write_data(protocol, Protocol::Message.new(Protocol::Message::TYPE_AUTHENTICATION, authenticated.merge(session_id: @session&.id)))
        return close unless authenticated[:success]

        sync = protocol.decoder.decode(read_frame, protocol.encoder.format)
        negotiated = protocol.handshake.negotiate(sync.payload[:capabilities] || {})
        @state = STATE_READY
        write_data(protocol, Protocol::Message.new(Protocol::Message::TYPE_READY_FOR_QUERY, negotiated))

        while !@closed && (line = read_frame)
          begin
            message = protocol.decoder.decode(line, protocol.encoder.format)
          rescue StandardError => e
            write_data(protocol, Protocol::Message.new(
              Protocol::Message::TYPE_ERROR,
              { success: false, error: "Invalid protocol frame: #{e.message}" }
            ))
            next
          end
          break if message.type.to_s == "terminate"
          request = message.payload.merge(type: message.type.to_s)
          response = begin
            @session.process(request)
          rescue StandardError => e
            { success: false, error: e.message, timestamp: Time.now.iso8601 }
          end
          @config[:connection_pool]&.record_request(response[:success] != false)
          response_type = response[:type] || "#{message.type}_response"
          write_data(protocol, Protocol::Message.new(response_type.to_sym, response))
        end
      rescue RequestTooLarge => e
        write_data(protocol, Protocol::Message.new(
          Protocol::Message::TYPE_ERROR,
          { success: false, error: e.message }
        )) rescue nil
        close unless @closed
      rescue RequestTimeout => e
        write_data(protocol, Protocol::Message.new(
          Protocol::Message::TYPE_ERROR,
          { success: false, error: e.message }
        )) rescue nil
        close unless @closed
      rescue StandardError => e
        warn "RubyDB connection #{@id} failed: #{e.class}: #{e.message}" if ENV["RUBYDB_DEBUG"]
        close unless @closed
      end

      def read_frame
        limit = Integer(@config[:max_request_size] || 10 * 1024 * 1024)
        timeout = @read_timeout
        if timeout && !IO.select([@client], nil, nil, timeout)
          raise RequestTimeout, "Request timed out after #{timeout} seconds"
        end
        # Passing the separator explicitly keeps the byte limit compatible
        # with both plain sockets and OpenSSL::SSL::SSLSocket.
        line = @client.gets("\n", limit + 1)
        return nil unless line

        if line.bytesize > limit || !line.end_with?("\n")
          raise RequestTooLarge, "Request frame exceeds maximum size of #{limit} bytes"
        end

        @bytes_received += line.bytesize
        line
      end

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
