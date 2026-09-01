# frozen_string_literal: true

require "json"
require "digest"
require "time"

module RubyDB
  module Protocol
    class Message
      TYPE_HANDSHAKE = :handshake
      TYPE_HANDSHAKE_RESPONSE = :handshake_response
      TYPE_QUERY = :query
      TYPE_QUERY_RESPONSE = :query_response
      TYPE_PREPARE = :prepare
      TYPE_PREPARE_RESPONSE = :prepare_response
      TYPE_EXECUTE = :execute
      TYPE_EXECUTE_RESPONSE = :execute_response
      TYPE_CLOSE = :close
      TYPE_CLOSE_RESPONSE = :close_response
      TYPE_PING = :ping
      TYPE_PONG = :pong
      TYPE_ERROR = :error
      TYPE_NOTICE = :notice
      TYPE_PARAMETER_DESCRIPTION = :parameter_description
      TYPE_ROW_DESCRIPTION = :row_description
      TYPE_DATA_ROW = :data_row
      TYPE_COMMAND_COMPLETE = :command_complete
      TYPE_READY_FOR_QUERY = :ready_for_query
      TYPE_BEGIN = :begin
      TYPE_COMMIT = :commit
      TYPE_ROLLBACK = :rollback
      TYPE_SYNCHRONIZE = :synchronize
      TYPE_CANCEL = :cancel
      TYPE_TERMINATE = :terminate
      TYPE_AUTHENTICATION = :authentication
      TYPE_AUTHENTICATION_RESPONSE = :authentication_response

      attr_reader :type, :id, :created_at, :payload

      def initialize(type, payload = {})
        @type = type
        @id = "msg_#{Time.now.to_i}_#{rand(10000)}"
        @created_at = Time.now
        @payload = payload
        @compressed = false
        @encrypted = false
        @checksum = nil
      end

      def compress
        return self if @compressed
        @compressed = true
        self
      end

      def decompress
        return self unless @compressed
        @compressed = false
        self
      end

      def encrypt(key)
        return self if @encrypted
        @encrypted = true
        self
      end

      def decrypt(key)
        return self unless @encrypted
        @encrypted = false
        self
      end

      def calculate_checksum
        data = "#{@type}#{@id}#{JSON.generate(@payload)}"
        Digest::SHA256.hexdigest(data)[0...16]
      end

      def verify_checksum
        return true if @checksum.nil?
        @checksum == calculate_checksum
      end

      def to_hash
        {
          type: @type,
          id: @id,
          created_at: @created_at.iso8601,
          payload: @payload,
          compressed: @compressed,
          encrypted: @encrypted,
          checksum: @checksum
        }
      end

      def to_json
        JSON.generate(to_hash)
      end

      def self.from_json(json_data)
        data = JSON.parse(json_data, symbolize_names: true)
        msg = new(data[:type], data[:payload] || {})
        msg.instance_variable_set(:@id, data[:id])
        msg.instance_variable_set(:@created_at, Time.parse(data[:created_at]))
        msg.instance_variable_set(:@compressed, data[:compressed] || false)
        msg.instance_variable_set(:@encrypted, data[:encrypted] || false)
        msg.instance_variable_set(:@checksum, data[:checksum])
        msg
      end

      def inspect
        "#<Message type=#{@type} id=#{@id}>"
      end

      def to_s
        inspect
      end
    end
  end
end