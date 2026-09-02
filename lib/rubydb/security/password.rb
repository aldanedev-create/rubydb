# frozen_string_literal: true

require "digest"
require "securerandom"
require "base64"
require "monitor"

module RubyDB
  module Security
    # Password - Handles password hashing and validation
    class Password
      # Password algorithms
      ALGORITHM_SHA256 = :sha256
      ALGORITHM_SHA512 = :sha512
      ALGORITHM_BCRYPT = :bcrypt
      ALGORITHM_PBKDF2 = :pbkdf2
      ALGORITHM_ARGON2 = :argon2

      def initialize(config = {})
        @algorithm = config[:algorithm] || ALGORITHM_SHA256
        @iterations = config[:iterations] || 10000
        @salt_length = config[:salt_length] || 16
        @key_length = config[:key_length] || 32
        @bcrypt_cost = config[:bcrypt_cost] || 10
        @stats = {
          hashes: 0,
          verifications: 0,
          verifications_successful: 0,
          verifications_failed: 0,
          salts_generated: 0
        }
        @lock = Monitor.new
      end

      def hash(password, salt = nil)
        @lock.synchronize do
          @stats[:hashes] += 1
          salt ||= generate_salt

          hash_data = case @algorithm
          when ALGORITHM_SHA256
            hash_sha256(password, salt)
          when ALGORITHM_SHA512
            hash_sha512(password, salt)
          when ALGORITHM_BCRYPT
            hash_bcrypt(password)
          when ALGORITHM_PBKDF2
            hash_pbkdf2(password, salt)
          when ALGORITHM_ARGON2
            hash_argon2(password, salt)
          else
            raise ArgumentError, "Unsupported password algorithm: #{@algorithm}"
          end

          {
            algorithm: @algorithm,
            salt: salt,
            hash: hash_data,
            iterations: @iterations,
            key_length: @key_length
          }
        end
      end

      def verify(password, stored_hash)
        @lock.synchronize do
          @stats[:verifications] += 1

          algorithm = stored_hash[:algorithm] || @algorithm
          salt = stored_hash[:salt]
          hash_data = stored_hash[:hash]

          result = case algorithm
          when ALGORITHM_SHA256
            verify_sha256(password, salt, hash_data)
          when ALGORITHM_SHA512
            verify_sha512(password, salt, hash_data)
          when ALGORITHM_BCRYPT
            verify_bcrypt(password, hash_data)
          when ALGORITHM_PBKDF2
            verify_pbkdf2(password, salt, hash_data, stored_hash[:iterations] || @iterations)
          when ALGORITHM_ARGON2
            verify_argon2(password, salt, hash_data)
          else
            false
          end

          if result
            @stats[:verifications_successful] += 1
          else
            @stats[:verifications_failed] += 1
          end

          result
        end
      end

      def generate_salt
        @lock.synchronize do
          @stats[:salts_generated] += 1
          SecureRandom.hex(@salt_length)
        end
      end

      def meets_policy?(password)
        # Check password policy
        return false if password.length < 8
        return false unless password.match?(/[a-z]/)
        return false unless password.match?(/[A-Z]/)
        return false unless password.match?(/\d/)
        return false unless password.match?(/[^a-zA-Z0-9]/)
        true
      end

      def generate_random_password(length = 16)
        charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()"
        (0...length).map { charset[SecureRandom.rand(charset.length)] }.join
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            algorithm: @algorithm,
            iterations: @iterations,
            salt_length: @salt_length,
            key_length: @key_length
          })
        end
      end

      private

      def hash_sha256(password, salt)
        Digest::SHA256.hexdigest(salt + password)
      end

      def verify_sha256(password, salt, stored_hash)
        hash_sha256(password, salt) == stored_hash
      end

      def hash_sha512(password, salt)
        Digest::SHA512.hexdigest(salt + password)
      end

      def verify_sha512(password, salt, stored_hash)
        hash_sha512(password, salt) == stored_hash
      end

      def hash_bcrypt(password)
        begin
          require "bcrypt"
          BCrypt::Password.create(password, cost: @bcrypt_cost)
        rescue LoadError
          raise ArgumentError, "bcrypt support requires the bcrypt gem"
        end
      end

      def verify_bcrypt(password, stored_hash)
        begin
          require "bcrypt"
          BCrypt::Password.new(stored_hash) == password
        rescue LoadError
          false
        end
      end

      def hash_pbkdf2(password, salt)
        begin
          require "openssl"
          OpenSSL::PKCS5.pbkdf2_hmac(
            password,
            salt,
            @iterations,
            @key_length,
            "sha256"
          ).unpack1("H*")
        rescue LoadError
          hash_sha256(password, salt)
        end
      end

      def verify_pbkdf2(password, salt, stored_hash, iterations)
        require "openssl"
        computed = OpenSSL::PKCS5.pbkdf2_hmac(
          password,
          salt,
          iterations,
          @key_length,
          "sha256"
        ).unpack1("H*")
        computed == stored_hash
      rescue LoadError
        false
      end

      def hash_argon2(password, salt)
        begin
          require "argon2"
          Argon2::Password.create(password)
        rescue LoadError
          raise ArgumentError, "argon2 support requires the argon2 gem"
        end
      end

      def verify_argon2(password, salt, stored_hash)
        begin
          require "argon2"
          Argon2::Password.verify_password(password, stored_hash)
        rescue LoadError
          false
        end
      end
    end
  end
end
