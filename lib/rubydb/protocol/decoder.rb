v# frozen_string_literal: true

require "zlib"
require "base64"

module RubyDB
  module Protocol
    class Decoder
      attr_reader :stats

      def initialize(options = {})
        @options = options
        @encryption_key = options[:encryption_key]
        @stats = {
          messages_decoded: 0,
          bytes_decoded: 0,
          decompressions: 0,
          decryption_ops: 0,
          errors: 0
        }
        @lock = Mutex.new
      end

      def decode(data, format = Encoder::FORMAT_JSON)
        @lock.synchronize do
          @stats[:bytes_decoded] += data.bytesize

          begin
            if @encryption_key && encrypted?(data)
              data = decrypt(data)
              @stats[:decryption_ops] += 1
            end

            if compressed?(data)
              data = decompress(data)
              @stats[:decompressions] += 1
            end

            message = case format
            when Encoder::FORMAT_JSON
              decode_json(data)
            when Encoder::FORMAT_MSGPACK
              decode_msgpack(data)
            when Encoder::FORMAT_BINARY
              decode_binary(data)
            else
              decode_json(data)
            end

            @stats[:messages_decoded] += 1
            message

          rescue => e
            @stats[:errors] += 1
            raise ProtocolError, "Decoding failed: #{e.message}"
          end
        end
      end

      def decode_json(data)
        Message.from_json(data)
      end

      def decode_msgpack(data)
        begin
          require "msgpack"
          hash = MessagePack.unpack(data)
          msg = Message.new(hash[:type], hash[:payload] || {})
          msg.instance_variable_set(:@id, hash[:id])
          msg.instance_variable_set(:@created_at, Time.parse(hash[:created_at]))
          msg
        rescue LoadError
          decode_json(data)
        end
      end

      def decode_binary(data)
        offset = 0

        type_len = data[offset].unpack("C").first
        offset += 1
        type = data[offset, type_len].to_sym
        offset += type_len

        id_len = data[offset].unpack("C").first
        offset += 1
        id = data[offset, id_len]
        offset += id_len

        timestamp = data[offset, 8].unpack("Q>").first
        offset += 8

        payload_len = data[offset, 4].unpack("L>").first
        offset += 4
        payload_data = data[offset, payload_len]
        payload = JSON.parse(payload_data, symbolize_names: true)

        msg = Message.new(type, payload)
        msg.instance_variable_set(:@id, id)
        msg.instance_variable_set(:@created_at, Time.at(timestamp))
        msg
      end

      def compressed?(data)
        data.bytesize >= 2 && data[0].ord == 0x78 && (data[1].ord == 0x01 || data[1].ord == 0x9C || data[1].ord == 0xDA)
      end

      def decompress(data)
        Zlib::Inflate.inflate(data)
      rescue => e
        raise ProtocolError, "Decompression failed: #{e.message}"
      end

      def encrypted?(data)
        false
      end

      def decrypt(data)
        return data unless @encryption_key

        begin
          require "openssl"
          iv = data[0, 16]
          encrypted_data = data[16..-1]

          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.decrypt
          cipher.key = @encryption_key
          cipher.iv = iv
          cipher.update(encrypted_data) + cipher.final
        rescue => e
          raise ProtocolError, "Decryption failed: #{e.message}"
        end
      end

      def stats
        @lock.synchronize do
          @stats.merge({
            bytes_per_message: @stats[:messages_decoded] > 0 ? @stats[:bytes_decoded] / @stats[:messages_decoded] : 0
          })
        end
      end
    end
  end
end