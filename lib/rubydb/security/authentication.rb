# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"
require "base64"

module RubyDB
  module Security
    # Authentication - Handles user authentication
    class Authentication
      attr_reader :stats

      # Authentication methods
      METHOD_NONE = :none
      METHOD_PASSWORD = :password
      METHOD_MD5 = :md5
      METHOD_SCRAM_SHA256 = :scram_sha256
      METHOD_TOKEN = :token
      METHOD_CERTIFICATE = :certificate

      def initialize(config = {})
        @config = config
        @method = config[:method] || METHOD_PASSWORD
        @session_timeout = config[:session_timeout] || 3600
        @max_attempts = config[:max_attempts] || 5
        @lockout_duration = config[:lockout_duration] || 900
        @user_store = config[:user_store] || {}
        @sessions = {}
        @failed_attempts = {}
        @locked_users = {}
        @tokens = {}
        @stats = {
          authentications: 0,
          successful: 0,
          failed: 0,
          lockouts: 0,
          active_sessions: 0,
          token_issued: 0,
          token_validated: 0
        }
        @lock = Mutex.new
      end

      def authenticate(credentials)
        @lock.synchronize do
          @stats[:authentications] += 1
          username = credentials[:username]
          password = credentials[:password]

          # Check if user is locked out
          if locked_out?(username)
            @stats[:failed] += 1
            return { success: false, error: "User is locked out" }
          end

          # Find user
          user = find_user(username)
          unless user
            record_failed_attempt(username)
            @stats[:failed] += 1
            return { success: false, error: "Invalid credentials" }
          end

          # Authenticate based on method
          authenticated = case @method
          when METHOD_NONE
            true
          when METHOD_PASSWORD
            authenticate_password(user, password)
          when METHOD_MD5
            authenticate_md5(user, password, credentials[:salt])
          when METHOD_SCRAM_SHA256
            authenticate_scram(user, credentials[:scram_data])
          when METHOD_TOKEN
            authenticate_token(user, credentials[:token])
          when METHOD_CERTIFICATE
            authenticate_certificate(user, credentials[:certificate])
          else
            authenticate_password(user, password)
          end

          if authenticated
            # Create session
            session = create_session(user)
            @stats[:successful] += 1
            @failed_attempts.delete(username)

            {
              success: true,
              user: user,
              session: session,
              token: session[:token]
            }
          else
            record_failed_attempt(username)
            @stats[:failed] += 1
            { success: false, error: "Invalid credentials" }
          end
        end
      end

      def validate_session(token)
        @lock.synchronize do
          @stats[:token_validated] += 1

          session = @sessions[token]
          return false unless session

          # Check if session expired
          if Time.now - session[:created_at] > @session_timeout
            @sessions.delete(token)
            return false
          end

          # Update last activity
          session[:last_activity] = Time.now
          true
        end
      end

      def invalidate_session(token)
        @lock.synchronize do
          @sessions.delete(token)
        end
      end

      def invalidate_all_sessions(username)
        @lock.synchronize do
          @sessions.delete_if { |_, s| s[:username] == username }
        end
      end

      def create_token(username, expires_in = 3600)
        @lock.synchronize do
          @stats[:token_issued] += 1
          token = generate_token(username)
          @tokens[token] = {
            username: username,
            created_at: Time.now,
            expires_at: Time.now + expires_in
          }
          token
        end
      end

      def validate_token(token)
        @lock.synchronize do
          token_data = @tokens[token]
          return false unless token_data

          if Time.now > token_data[:expires_at]
            @tokens.delete(token)
            return false
          end

          token_data[:username]
        end
      end

      def revoke_token(token)
        @lock.synchronize do
          @tokens.delete(token)
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            method: @method,
            session_timeout: @session_timeout,
            active_sessions: @sessions.size,
            locked_users: @locked_users.size,
            tokens: @tokens.size
          })
        end
      end

      private

      def find_user(username)
        @user_store[username]
      end

      def authenticate_password(user, password)
        return false unless user && password
        user.password_hash == hash_password(password, user.salt)
      end

      def authenticate_md5(user, password, salt)
        return false unless user && password
        expected = Digest::MD5.hexdigest(password + salt)
        expected == user.password_hash
      end

      def authenticate_scram(user, scram_data)
        return false unless user && scram_data
        # In production, implement full SCRAM verification
        verify_scram_response(user, scram_data)
      end

      def authenticate_token(user, token)
        return false unless user && token
        user.token == token
      end

      def authenticate_certificate(user, certificate)
        return false unless user && certificate
        user.certificate == certificate
      end

      def create_session(user)
        token = generate_token(user.username)
        session = {
          username: user.username,
          created_at: Time.now,
          last_activity: Time.now,
          token: token,
          user: user
        }
        @sessions[token] = session
        @stats[:active_sessions] = @sessions.size
        session
      end

      def generate_token(username)
        "#{username}_#{Time.now.to_i}_#{SecureRandom.hex(16)}"
      end

      def hash_password(password, salt)
        Digest::SHA256.hexdigest(salt + password)
      end

      def record_failed_attempt(username)
        @failed_attempts[username] ||= 0
        @failed_attempts[username] += 1

        if @failed_attempts[username] >= @max_attempts
          @locked_users[username] = Time.now + @lockout_duration
          @stats[:lockouts] += 1
        end
      end

      def locked_out?(username)
        lock_expiry = @locked_users[username]
        return false unless lock_expiry

        if Time.now > lock_expiry
          @locked_users.delete(username)
          @failed_attempts.delete(username)
          return false
        end

        true
      end

      def verify_scram_response(user, scram_data)
        # Placeholder for SCRAM verification
        true
      end
    end
  end
end