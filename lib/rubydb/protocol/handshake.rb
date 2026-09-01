# frozen_string_literal: true

require "securerandom"
require "digest"

module RubyDB
  module Protocol
    class Handshake
      STATE_INIT = :init
      STATE_AUTHENTICATING = :authenticating
      STATE_AUTHENTICATED = :authenticated
      STATE_NEGOTIATING = :negotiating
      STATE_COMPLETE = :complete
      STATE_FAILED = :failed

      attr_reader :state, :client_info, :server_info

      def initialize(server_info = {})
        @state = STATE_INIT
        @client_info = {}
        @server_info = {
          version: ProtocolVersion.current_string,
          protocol_version: ProtocolVersion.current,
          name: "RubyDB",
          pid: Process.pid,
          started_at: Time.now.iso8601,
          auth_methods: ["none", "password", "md5", "scram-sha-256"],
          default_auth: "none"
        }.merge(server_info)
        @challenge = nil
        @authenticated = false
        @capabilities = nil
        @start_time = Time.now
        @timeout = 30
        @max_attempts = 3
        @attempts = 0
        @lock = Mutex.new
      end

      def start(client_info = {})
        @lock.synchronize do
          @state = STATE_INIT
          @client_info = client_info
          @attempts += 1

          client_version = client_info[:protocol_version]
          unless client_version
            return error_response("Protocol version not specified")
          end

          unless ProtocolVersion.supported?(client_version)
            return error_response("Unsupported protocol version: #{ProtocolVersion.to_string(client_version)}")
          end

          unless ProtocolVersion.compatible?(client_version, @server_info[:protocol_version])
            return error_response("Incompatible protocol version")
          end

          @state = STATE_AUTHENTICATING
          authentication_response(client_info)
        end
      end

      def authenticate(credentials)
        @lock.synchronize do
          return error_response("Handshake not initialized") if @state == STATE_INIT

          @state = STATE_AUTHENTICATING

          auth_method = @client_info[:auth_method] || @server_info[:default_auth]

          case auth_method
          when "none"
            @authenticated = true
            @state = STATE_AUTHENTICATED
            return success_response
          when "password"
            @authenticated = authenticate_password(credentials)
          when "md5"
            @authenticated = authenticate_md5(credentials)
          when "scram-sha-256"
            @authenticated = authenticate_scram(credentials)
          else
            return error_response("Unsupported authentication method: #{auth_method}")
          end

          if @authenticated
            @state = STATE_AUTHENTICATED
            success_response
          else
            @state = STATE_FAILED
            error_response("Authentication failed")
          end
        end
      end

      def negotiate(capabilities)
        @lock.synchronize do
          return error_response("Not authenticated") unless @authenticated

          @state = STATE_NEGOTIATING
          @capabilities = capabilities

          negotiated = negotiate_capabilities(capabilities)

          @state = STATE_COMPLETE
          negotiated_response(negotiated)
        end
      end

      def complete?
        @state == STATE_COMPLETE
      end

      def authenticated?
        @authenticated
      end

      def failed?
        @state == STATE_FAILED
      end

      def timed_out?
        Time.now - @start_time > @timeout
      end

      def max_attempts_reached?
        @attempts >= @max_attempts
      end

      def reset
        @lock.synchronize do
          @state = STATE_INIT
          @authenticated = false
          @challenge = nil
          @capabilities = nil
          @attempts = 0
          @start_time = Time.now
        end
      end

      def to_hash
        {
          state: @state,
          authenticated: @authenticated,
          client_info: @client_info,
          server_info: @server_info,
          capabilities: @capabilities,
          attempts: @attempts,
          elapsed: (Time.now - @start_time).round(2)
        }
      end

      private

      def success_response
        {
          success: true,
          state: @state,
          server_info: @server_info,
          message: "Handshake successful"
        }
      end

      def error_response(message)
        {
          success: false,
          state: @state,
          error: message,
          attempts_remaining: @max_attempts - @attempts
        }
      end

      def authentication_response(client_info)
        {
          success: true,
          auth_methods: @server_info[:auth_methods],
          default_auth: @server_info[:default_auth],
          challenge: generate_challenge
        }
      end

      def negotiated_response(negotiated)
        {
          success: true,
          state: @state,
          negotiated: negotiated,
          server_info: @server_info
        }
      end

      def generate_challenge
        @challenge = SecureRandom.hex(16)
      end

      def authenticate_password(credentials)
        username = credentials[:username]
        password = credentials[:password]
        !username.nil? && !password.nil?
      end

      def authenticate_md5(credentials)
        username = credentials[:username]
        password = credentials[:password]

        return false if username.nil? || password.nil?

        expected = Digest::MD5.hexdigest(password + @challenge)
        actual = credentials[:md5_hash]

        actual == expected
      end

      def authenticate_scram(credentials)
        return false if credentials[:scram_data].nil?
        verify_scram_response(credentials[:scram_data])
      end

      def verify_scram_response(scram_data)
        # In production, this would verify the SCRAM response
        scram_data.is_a?(String) && scram_data.length > 0
      end

      def negotiate_capabilities(capabilities)
        {
          protocol_version: ProtocolVersion.current,
          compression: capabilities[:compression] && @server_info[:compression_supported],
          encryption: capabilities[:encryption] && @server_info[:encryption_supported],
          pipeline: capabilities[:pipeline] && @server_info[:pipeline_supported],
          batch_size: [capabilities[:batch_size] || 100, @server_info[:max_batch_size] || 1000].min,
          timeout: [capabilities[:timeout] || 30, @server_info[:max_timeout] || 300].min,
          max_rows: [capabilities[:max_rows] || 10000, @server_info[:max_rows] || 100000].min
        }
      end
    end
  end
end