# frozen_string_literal: true

require "zlib"
require "base64"

module RubyDB
  module Protocol
    class Encoder
      FORMAT_JSON = :json
      FORMAT_MSGPACK = :msgpack
      FORMAT_BINARY = :binary

      attr_reader :stats

      def initialize(format = FORMAT_JSON, options = {})
        @format = format
        @options = options
        @compression = options[:compression] || false
        @encryption = options[:encryption] || false
        @encryption_key = options[:encryption_key]
        @stats = {
          messages_encoded: 0,
          bytes_encoded: 0,
          compressions: 0,
          encryption_ops: 0,
          errors: 0
        }
        @lock = Mutex.new
      end

      def encode(message)
        @lock.synchronize do
          @stats[:messages_encoded] += 1

          begin
          data = case @format
            when FORMAT_JSON
              encode_json(message)
            when FORMAT_MSGPACK
              encode_msgpack(message)
            when FORMAT_BINARY
              encode_binary(message)
            else
              encode_json(message)
            end

            # JSON messages are transported as one line per frame so a
            # persistent TCP connection can separate responses reliably.
            data << "\n" if @format == FORMAT_JSON && !data.end_with?("\n")

            if @compression
              data = compress(data)
              @stats[:compressions] += 1
            end

            if @encryption && @encryption_key
              data = encrypt(data)
              @stats[:encryption_ops] += 1
            end

            @stats[:bytes_encoded] += data.bytesize
            data

          rescue => e
            @stats[:errors] += 1
            raise ProtocolError, "Encoding failed: #{e.message}"
          end
        end
      end

      def encode_json(message)
        message.to_json
      end

      def encode_msgpack(message)
        begin
          require "msgpack"
          MessagePack.pack(message.to_hash)
        rescue LoadError
          message.to_json
        end
      end

      def encode_binary(message)
        data = ""
        data << [message.type.to_s.bytesize].pack("C")
        data << message.type.to_s
        data << [message.id.bytesize].pack("C")
        data << message.id
        data << [message.created_at.to_i].pack("Q>")
        payload = JSON.generate(message.payload)
        data << [payload.bytesize].pack("L>")
        data << payload
        data
      end

      def compress(data)
        Zlib::Deflate.deflate(data)
      rescue => e
        raise ProtocolError, "Compression failed: #{e.message}"
      end

      def encrypt(data)
        return data unless @encryption_key

        begin
          require "openssl"
          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.encrypt
          cipher.key = @encryption_key
          cipher.iv = cipher.random_iv
          encrypted = cipher.update(data) + cipher.final
          iv = cipher.iv
          iv + encrypted
        rescue => e
          raise ProtocolError, "Encryption failed: #{e.message}"
        end
      end

      def format
        @format
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            format: @format,
            compression: @compression,
            encryption: @encryption,
            bytes_per_message: @stats[:messages_encoded] > 0 ? @stats[:bytes_encoded] / @stats[:messages_encoded] : 0
          })
        end
      end
    end
  end
end
