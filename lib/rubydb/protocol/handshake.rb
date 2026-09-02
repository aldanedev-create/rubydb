# frozen_string_literal: true

require "securerandom"
require "digest"
require "openssl"
require "base64"

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
        server_info = (server_info || {}).dup
        @credentials = server_info.delete(:authentication_credentials) || {}
        @server_info = {
          version: ProtocolVersion.current_string,
          protocol_version: ProtocolVersion.current,
          name: "RubyDB",
          pid: Process.pid,
          started_at: Time.now.iso8601,
          auth_methods: ["none", "password", "md5", "scram-sha-256"],
          default_auth: "none"
        }.merge(server_info || {})
        @challenge = nil
        @scram_salt = (@credentials[:scram_salt] || @credentials["scram_salt"])
        @scram_salt = SecureRandom.random_bytes(16) unless @scram_salt
        @scram_iterations = Integer(@credentials[:scram_iterations] || @credentials["scram_iterations"] || 120_000)
        @scram_server_signature = nil
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

          # The server selects the required mechanism; clients cannot lower
          # the server's authentication policy by requesting "none".
          auth_method = @server_info[:default_auth]

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
        response = {
          success: true,
          state: @state,
          server_info: @server_info,
          message: "Handshake successful"
        }
        response[:server_signature] = @scram_server_signature if @scram_server_signature
        response
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
        response = {
          success: true,
          auth_methods: @server_info[:auth_methods],
          default_auth: @server_info[:default_auth],
          challenge: generate_challenge
        }
        if @server_info[:default_auth] == "scram-sha-256"
          response[:scram_salt] = Base64.strict_encode64(@scram_salt)
          response[:scram_iterations] = @scram_iterations
        end
        response
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
        return false if username.nil? || password.nil?

        users = @credentials[:users] || @credentials["users"]
        if users
          expected = users[username] || users[username.to_s] || users[username.to_sym]
          return secure_equal?(password.to_s, expected.to_s) unless expected.nil?
          return false
        end

        expected_username = @credentials[:username] || @credentials["username"]
        expected_password = @credentials[:password] || @credentials["password"]
        return false if expected_username.nil? || expected_password.nil?

        secure_equal?(username.to_s, expected_username.to_s) &&
          secure_equal?(password.to_s, expected_password.to_s)
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        result = 0
        left.bytes.each_with_index { |byte, index| result |= byte ^ right.getbyte(index) }
        result.zero?
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
        data = credentials[:scram_data]
        return false unless data.is_a?(Hash)

        username = credentials[:username].to_s
        client_first_bare = data[:client_first_bare] || data["client_first_bare"]
        client_final = data[:client_final_without_proof] || data["client_final_without_proof"]
        proof = data[:proof] || data["proof"]
        client_nonce = data[:client_nonce] || data["client_nonce"]
        return false if [client_first_bare, client_final, proof, client_nonce].any?(&:nil?)
        return false unless client_first_bare.include?("n=#{username},")
        return false unless client_first_bare.include?("r=#{client_nonce}")

        server_nonce = @challenge.to_s
        expected_nonce = client_nonce.to_s + server_nonce
        return false unless client_final == "c=biws,r=#{expected_nonce}"

        password = @credentials[:password] || @credentials["password"]
        stored_key = @credentials[:scram_stored_key] || @credentials["scram_stored_key"]
        server_key = @credentials[:scram_server_key] || @credentials["scram_server_key"]
        return false unless password || (stored_key && server_key)

        salted = OpenSSL::PKCS5.pbkdf2_hmac(password.to_s, @scram_salt, @scram_iterations, 32, OpenSSL::Digest::SHA256.new) if password
        stored_key ||= Digest::SHA256.digest(OpenSSL::HMAC.digest("SHA256", salted, "Client Key"))
        server_key ||= OpenSSL::HMAC.digest("SHA256", salted, "Server Key")
        stored_key = Base64.decode64(stored_key) if stored_key.is_a?(String) && stored_key.match?(/\A[A-Za-z0-9+\/=]+\z/) && stored_key.bytesize != 32
        server_key = Base64.decode64(server_key) if server_key.is_a?(String) && server_key.match?(/\A[A-Za-z0-9+\/=]+\z/) && server_key.bytesize != 32

        auth_message = [client_first_bare, "r=#{expected_nonce},s=#{Base64.strict_encode64(@scram_salt)},i=#{@scram_iterations}", client_final].join(",")
        proof_bytes = Base64.decode64(proof.to_s)
        client_signature = OpenSSL::HMAC.digest("SHA256", stored_key, auth_message)
        client_key = proof_bytes.bytes.each_with_index.map { |byte, index| byte ^ client_signature.getbyte(index) }.pack("C*")
        valid = secure_equal?(Digest::SHA256.digest(client_key), stored_key)
        if valid
          @scram_server_signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", server_key, auth_message))
        end
        valid
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
