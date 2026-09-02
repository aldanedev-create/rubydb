# frozen_string_literal: true

require "time"

module RubyDB
  module WAL
    # LSN - Log Sequence Number for identifying WAL records
    class LSN
      attr_reader :segment_id, :offset, :timestamp

      def initialize(segment_id = 0, offset = 0, timestamp = nil)
        @segment_id = segment_id
        @offset = offset
        @timestamp = timestamp || Time.now
      end

      def to_i
        (@segment_id << 32) | @offset
      end

      def to_s
        "LSN(#{@segment_id}, #{@offset})"
      end

      def inspect
        to_s
      end

      def ==(other)
        other.is_a?(LSN) && @segment_id == other.segment_id && @offset == other.offset
      end

      def <(other)
        return false unless other.is_a?(LSN)
        @segment_id < other.segment_id || (@segment_id == other.segment_id && @offset < other.offset)
      end

      def <=(other)
        self < other || self == other
      end

      def >(other)
        return false unless other.is_a?(LSN)
        @segment_id > other.segment_id || (@segment_id == other.segment_id && @offset > other.offset)
      end

      def >=(other)
        self > other || self == other
      end

      def to_i64
        [@segment_id, @offset].pack("Q>Q>")
      end

      def self.from_i64(data)
        segment_id, offset = data.unpack("Q>Q>")
        new(segment_id, offset)
      end

      def self.from_i(value)
        segment_id = value >> 32
        offset = value & 0xFFFFFFFF
        new(segment_id, offset)
      end

      def self.from_s(value)
        match = value.to_s.match(/\ALSN\((\d+),\s*(\d+)\)\z/)
        raise ArgumentError, "Invalid LSN: #{value.inspect}" unless match

        new(match[1].to_i, match[2].to_i)
      end

      def self.null
        new(0, 0)
      end

      def null?
        @segment_id == 0 && @offset == 0
      end

      def serialize
        {
          segment_id: @segment_id,
          offset: @offset,
          timestamp: @timestamp.iso8601
        }
      end

      def self.deserialize(data)
        new(data[:segment_id], data[:offset], Time.parse(data[:timestamp]))
      end
    end
  end
end
