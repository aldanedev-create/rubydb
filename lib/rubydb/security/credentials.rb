# frozen_string_literal: true

require "json"
require "fileutils"
require "openssl"

module RubyDB
  module Security
    # Credentials - Manages credential storage
    class Credentials
      attr_reader :stats

      def initialize(config = {})
        @config = config
        @storage_path = config[:storage_path] || "credentials.json"
        @encryption_key = config[:encryption_key]
        @credentials = {}
        @loaded = false
        @stats = {
          loaded: 0,
          saved: 0,
          encrypted: 0,
          decrypted: 0,
          errors: 0
        }
        @lock = Mutex.new

        load_credentials if File.exist?(@storage_path)
      end

      def add_credential(service, username, password, metadata = {})
        @lock.synchronize do
          @credentials[service] ||= {}
          @credentials[service][username] = {
            password: password,
            metadata: metadata,
            created_at: Time.now.iso8601,
            updated_at: Time.now.iso8601
          }
          save_credentials
        end
      end

      def get_credential(service, username)
        @lock.synchronize do
          load_credentials unless @loaded
          return nil unless @credentials[service]
          @credentials[service][username]
        end
      end

      def remove_credential(service, username)
        @lock.synchronize do
          return false unless @credentials[service]
          result = @credentials[service].delete(username)
          save_credentials if result
          result
        end
      end

      def list_services
        @lock.synchronize do
          load_credentials unless @loaded
          @credentials.keys
        end
      end

      def list_usernames(service)
        @lock.synchronize do
          load_credentials unless @loaded
          return [] unless @credentials[service]
          @credentials[service].keys
        end
      end

      def validate_credential(service, username, password)
        @lock.synchronize do
          cred = get_credential(service, username)
          return false unless cred
          cred[:password] == password
        end
      end

      def update_credential(service, username, new_password, metadata = nil)
        @lock.synchronize do
          cred = get_credential(service, username)
          return false unless cred
          cred[:password] = new_password
          cred[:updated_at] = Time.now.iso8601
          cred[:metadata] = metadata if metadata
          save_credentials
          true
        end
      end

      def encrypt_file
        @lock.synchronize do
          return unless @encryption_key

          @stats[:encrypted] += 1
          encrypted_path = "#{@storage_path}.encrypted"

          # Read file
          data = File.read(@storage_path)

          # Encrypt
          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.encrypt
          cipher.key = @encryption_key
          cipher.iv = cipher.random_iv

          encrypted = cipher.update(data) + cipher.final
          iv = cipher.iv

          # Write encrypted
          File.write(encrypted_path, iv + encrypted)
          File.delete(@storage_path)

          @storage_path = encrypted_path
        end
      end

      def decrypt_file
        @lock.synchronize do
          return unless @encryption_key && File.exist?(@storage_path)

          @stats[:decrypted] += 1
          decrypted_path = @storage_path.gsub(/\.encrypted$/, ".json")

          # Read encrypted
          data = File.read(@storage_path)

          # Decrypt
          iv = data[0, 16]
          encrypted = data[16..-1]

          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.decrypt
          cipher.key = @encryption_key
          cipher.iv = iv

          decrypted = cipher.update(encrypted) + cipher.final

          # Write decrypted
          File.write(decrypted_path, decrypted)
          File.delete(@storage_path)

          @storage_path = decrypted_path
          load_credentials
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            credentials_count: @credentials.size,
            services_count: @credentials.keys.size,
            loaded: @loaded,
            storage_path: @storage_path,
            encrypted: @storage_path.end_with?(".encrypted")
          })
        end
      end

      private

      def load_credentials
        @lock.synchronize do
          begin
            if File.exist?(@storage_path)
              data = File.read(@storage_path)
              @credentials = JSON.parse(data, symbolize_names: true)
              @loaded = true
              @stats[:loaded] += 1
            end
          rescue => e
            @stats[:errors] += 1
            @credentials = {}
          end
        end
      end

      def save_credentials
        @lock.synchronize do
          begin
            data = JSON.generate(@credentials)
            File.write(@storage_path, data)
            @stats[:saved] += 1
          rescue => e
            @stats[:errors] += 1
          end
        end
      end
    end
  end
end