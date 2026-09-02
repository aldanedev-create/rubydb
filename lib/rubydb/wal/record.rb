# frozen_string_literal: true

require "json"
require "digest"
require "time"
require_relative "../errors/corruption_error"

module RubyDB
  module WAL
    # Record - A single WAL record
    class Record
      # Record types
      TYPE_BEGIN = :begin
      TYPE_COMMIT = :commit
      TYPE_ROLLBACK = :rollback
      TYPE_INSERT = :insert
      TYPE_UPDATE = :update
      TYPE_DELETE = :delete
      TYPE_CREATE_TABLE = :create_table
      TYPE_DROP_TABLE = :drop_table
      TYPE_CREATE_INDEX = :create_index
      TYPE_DROP_INDEX = :drop_index
      TYPE_CHECKPOINT = :checkpoint
      TYPE_SCHEMA_CHANGE = :schema_change
      TYPE_PREPARE = :prepare
      TYPE_SAVEPOINT = :savepoint

      attr_reader :lsn, :type, :data, :transaction_id, :timestamp
      attr_reader :checksum, :prev_lsn, :size

      def initialize(type, data = {}, transaction_id: nil, prev_lsn: nil)
        @type = type
        @data = data
        @transaction_id = transaction_id
        @prev_lsn = prev_lsn
        @timestamp = Time.now
        @lsn = nil
        @checksum = nil
        @size = 0
      end

      def serialize
        # Build record data
        record_data = {
          type: @type,
          transaction_id: @transaction_id,
          prev_lsn: @prev_lsn&.to_s,
          timestamp: @timestamp.iso8601,
          data: @data
        }

        json_data = JSON.generate(record_data)
        # The serialized payload is checksum (16 ASCII bytes) followed by JSON.
        # Segment framing is owned by Segment, so this is the payload size.
        @size = json_data.bytesize + 16

        # Calculate checksum
        @checksum = Digest::SHA256.hexdigest(json_data)[0...16]

        # Return serialized record
        {
          checksum: @checksum,
          data: json_data,
          size: @size
        }
      end

      def self.deserialize(raw_data, lsn)
        checksum = raw_data[0...16]
        json_data = raw_data[16..-1]

        # Verify checksum
        calculated = Digest::SHA256.hexdigest(json_data)[0...16]
        raise CorruptionError, "WAL record checksum mismatch" if calculated != checksum

        parsed = JSON.parse(json_data, symbolize_names: true)

        record = new(
          parsed[:type].to_sym,
          parsed[:data] || {},
          transaction_id: parsed[:transaction_id],
          prev_lsn: parsed[:prev_lsn] ? LSN.from_s(parsed[:prev_lsn]) : nil
        )
        record.instance_variable_set(:@timestamp, Time.parse(parsed[:timestamp]))
        record.instance_variable_set(:@lsn, lsn)
        record.instance_variable_set(:@checksum, checksum)
        record.instance_variable_set(:@size, raw_data.bytesize)

        record
      end

      def to_s
        "WALRecord(lsn=#{@lsn}, type=#{@type}, txn=#{@transaction_id})"
      end

      def inspect
        to_s
      end

      def size
        @size || 0
      end
    end
  end
end
