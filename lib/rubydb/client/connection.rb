# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "monitor"
require "openssl"
require "base64"
require "securerandom"

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
        @lock = Monitor.new
        @buffer = ""
      end

      def connect
        @lock.synchronize do
          return if @connected

          begin
            tcp_socket = TCPSocket.new(@config[:host], @config[:port])
            ssl = @config[:ssl]
            if ssl == true || ssl.is_a?(Hash) && (ssl[:enabled] || ssl["enabled"])
              context = OpenSSL::SSL::SSLContext.new
              context.verify_mode = if ssl[:verify_peer] || ssl["verify_peer"]
                OpenSSL::SSL::VERIFY_PEER
              else
                OpenSSL::SSL::VERIFY_NONE
              end
              context.ca_file = ssl[:ca_file] || ssl["ca_file"] if ssl.is_a?(Hash) && (ssl[:ca_file] || ssl["ca_file"])
              if ssl.is_a?(Hash) && (ssl[:cert_file] || ssl["cert_file"])
                context.cert = OpenSSL::X509::Certificate.new(File.binread(ssl[:cert_file] || ssl["cert_file"]))
              end
              if ssl.is_a?(Hash) && (ssl[:key_file] || ssl["key_file"])
                context.key = OpenSSL::PKey.read(File.binread(ssl[:key_file] || ssl["key_file"]))
              end
              if ssl.is_a?(Hash) && (ssl[:min_version] || ssl["min_version"])
                context.min_version = ssl[:min_version] || ssl["min_version"]
              end
              @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, context)
              @socket.hostname = @config[:host] if @socket.respond_to?(:hostname=)
              @socket.connect
            else
              @socket = tcp_socket
            end

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
          unwrap_result(receive_message.payload)
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
          receive_message.payload
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
          unwrap_result(receive_message.payload)
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
          receive_message.payload
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
          receive_message.payload
        end
      end

      def send_commit
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(Protocol::Message::TYPE_COMMIT)
          send_message(message)
          receive_message.payload
        end
      end

      def send_rollback
        @lock.synchronize do
          ensure_connected

          message = Protocol::Message.new(Protocol::Message::TYPE_ROLLBACK)
          send_message(message)
          receive_message.payload
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
        data = @socket.gets
        raise EOFError, "server closed connection" unless data
        @stats[:bytes_received] += data.bytesize
        @stats[:messages_received] += 1

        @protocol.decoder.decode(data, @protocol.encoder.format)
      rescue => e
        @stats[:errors] += 1
        raise ConnectionError, "Receive failed: #{e.message}"
      end

      def unwrap_result(payload)
        result = payload[:result]
        return payload unless result.is_a?(Hash)

        result.merge(success: payload[:success] != false)
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
            # Send authentication, including a real SCRAM proof when required.
            auth_payload = {
              username: @config[:username],
              password: @config[:password],
              auth_method: @config[:auth_method] || "none"
            }
            if response.payload[:default_auth].to_s == "scram-sha-256"
              auth_payload.delete(:password)
              scram_payload = scram_data(
                @config[:username].to_s,
                @config[:password].to_s,
                response.payload[:challenge].to_s,
                response.payload[:scram_salt].to_s,
                response.payload[:scram_iterations].to_i
              )
              expected_server_signature = scram_payload.delete(:expected_server_signature)
              auth_payload[:scram_data] = scram_payload
            end
            auth_msg = Protocol::Message.new(
              Protocol::Message::TYPE_AUTHENTICATION_RESPONSE,
              auth_payload
            )

            send_message(auth_msg)
            auth_response = receive_message

            if auth_response.type == Protocol::Message::TYPE_AUTHENTICATION && auth_response.payload[:success]
              if expected_server_signature && auth_response.payload[:server_signature] != expected_server_signature
                raise ConnectionError, "SCRAM server signature verification failed"
              end
              @authenticated = true
              @session_id = auth_response.payload[:session_id]

              # Complete capability negotiation before exposing the connection
              # to callers. The server will not process application requests
              # until it receives this synchronization frame.
              sync_msg = Protocol::Message.new(
                Protocol::Message::TYPE_SYNCHRONIZE,
                { capabilities: Protocol::Capabilities.default_client.to_hash }
              )
              send_message(sync_msg)
              ready_response = receive_message
              unless ready_response.type == Protocol::Message::TYPE_READY_FOR_QUERY
                raise ConnectionError, "Protocol synchronization failed"
              end
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

      def scram_data(username, password, challenge, encoded_salt, iterations)
        client_nonce = SecureRandom.hex(18)
        client_first_bare = "n=#{username},r=#{client_nonce}"
        server_nonce = client_nonce + challenge
        client_final = "c=biws,r=#{server_nonce}"
        salt = Base64.decode64(encoded_salt)
        salted = OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iterations, 32, OpenSSL::Digest::SHA256.new)
        auth_message = [client_first_bare, "r=#{server_nonce},s=#{encoded_salt},i=#{iterations}", client_final].join(",")
        client_key = OpenSSL::HMAC.digest("SHA256", salted, "Client Key")
        stored_key = OpenSSL::Digest::SHA256.digest(client_key)
        signature = OpenSSL::HMAC.digest("SHA256", stored_key, auth_message)
        proof = client_key.bytes.each_with_index.map { |byte, index| byte ^ signature.getbyte(index) }.pack("C*")
        server_key = OpenSSL::HMAC.digest("SHA256", salted, "Server Key")
        {
          client_first_bare: client_first_bare,
          client_final_without_proof: client_final,
          client_nonce: client_nonce,
          proof: Base64.strict_encode64(proof),
          expected_server_signature: Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", server_key, auth_message))
        }
      end
    end
  end
end
